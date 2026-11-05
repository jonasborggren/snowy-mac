import Foundation

public final class SnowSimulation {
    public let size: SIMD2<Float>
    public let budget: SimulationBudget
    public internal(set) var flakes: [SnowParticle] = []
    public let looseSnow: GranularSnow
    let contour: GranularContour
    public internal(set) var drifts: [SnowDrift] = []
    public internal(set) var mesh: [SnowVertex] = []
    public internal(set) var elevatedMeshRanges: [Range<Int>] = []
    public internal(set) var meshRevision: UInt64 = 0
    public var snowfall: Snowfall = .steady
    /// When set, local weather drives the snowfall instead of the chosen preset. Zero means it isn't snowing.
    public var weatherDensity: Float? {
        didSet { if let value = weatherDensity, !value.isFinite { weatherDensity = 0 } }
    }
    public var snowDensity: Float { max(0, weatherDensity ?? snowfall.density) }
    public var reducedMotion = false
    public var particleScale: Float = 1
    public var wind = WindSettings() {
        didSet { if wind != oldValue { cornerWindDirty = true } }
    }
    public var tool: SnowTool = .glove

    // Shared only by SnowCore implementation extensions; none of this state is public.
    var random: RandomSource
    private var previousCursor: SIMD2<Float>?
    var buckets: [[Int]]
    var bodyBuckets: [[Int]]
    var bodies: [SolidBody] = []
    let bucketWidth: Float = 96
    var meshDirty = true
    var interactionDirty = false
    var geometryAge: Float = 0
    private var settleAge: Float = 0
    private var elapsed: Float = 0
    var lastSurfaces: [Surface] = []
    var pendingAppearances: [SolidBody] = []
    var batchingScene = false
    struct SupportTransfer {
        var targetID: UInt64
        var x: Float
        var baseY: Float
        var mass: Float
    }
    var supportTransfers: [SupportTransfer] = []
    struct SnowRelease {
        var position: SIMD2<Float>
        var height: Float
        var mass: Float
    }
    var snowReleases: [SnowRelease] = []
    var carriedContacts: [SnowRelease] = []
    var releaseScratch: [SnowRelease] = []
    var releaseIntervals: [Span] = []
    var intervalScratch: [Span] = []
    public var pendingTransferMass: Float {
        supportTransfers.reduce(0) { $0 + $1.mass } + snowReleases.reduce(0) { $0 + $1.mass }
            + carriedContacts.reduce(0) { $0 + $1.mass }
    }
    var cornerWindDirty = true

    public init(size: SIMD2<Float>, budget: SimulationBudget = SimulationBudget(), seed: UInt64 = 1) {
        let width = size.x.isFinite ? max(1, min(65_536, size.x)) : 1
        let height = size.y.isFinite ? max(1, min(65_536, size.y)) : 1
        self.size = SIMD2(width, height)
        self.budget = budget
        let field = GranularSnow(size: SIMD2(width, height), maxCells: budget.cells * 32,
                                maxActive: budget.maximumGranules)
        looseSnow = field
        contour = GranularContour(field: field)
        random = RandomSource(seed: seed)
        buckets = Array(repeating: [], count: max(1, Int(ceil(width / bucketWidth))))
        bodyBuckets = Array(repeating: [], count: buckets.count)
        flakes.reserveCapacity(budget.flakes)
        mesh.reserveCapacity(budget.maximumSnowVertices)
        elevatedMeshRanges.reserveCapacity(budget.surfaces)
        supportTransfers.reserveCapacity(budget.cells)
        snowReleases.reserveCapacity(budget.cells)
        carriedContacts.reserveCapacity(budget.cells)
        releaseScratch.reserveCapacity(budget.cells)
        releaseIntervals.reserveCapacity(DesktopSceneBuilder.maximumBodies + 1)
        intervalScratch.reserveCapacity(DesktopSceneBuilder.maximumBodies + 1)
    }

    public func resetPointer() { previousCursor = nil }

    public func clear() {
        for drift in drifts { drift.clear() }
        looseSnow.clear()
        supportTransfers.removeAll(keepingCapacity: true)
        snowReleases.removeAll(keepingCapacity: true)
        carriedContacts.removeAll(keepingCapacity: true)
        releaseScratch.removeAll(keepingCapacity: true)
        meshDirty = true
        resetPointer()
        if !batchingScene { rebuildMesh() }
    }

    /// Attached supports move first; then their boundaries displace the surrounding snow.
    public func updateScene(surfaces: [Surface], bodies: [SolidBody]) {
        looseSnow.beginFrame()
        batchingScene = true
        pendingAppearances.removeAll(keepingCapacity: true)
        let motions = persistentBodyMotions(to: bodies)
        captureSupportTransfers(to: surfaces, motions: motions)
        captureCarriedSnowCollisions(to: surfaces, motions: motions)
        updateSurfaces(surfaces, windBodies: bodies)
        updateBodies(bodies)
        refreshCornerWind()
        applySupportTransfers()
        // Contacts were captured before attachment transforms. Insert them only after
        // boundary pushes, so their carrier cannot sweep the detached material twice.
        if !carriedContacts.isEmpty {
            for release in carriedContacts { retainRelease(release, in: &snowReleases) }
            carriedContacts.removeAll(keepingCapacity: true)
            eraseReleasedSnow(inside: pendingAppearances)
        }
        applySnowReleases()
        batchingScene = false
        rebuildMesh()
    }

    public func step(dt rawDT: Float, cursor: SIMD2<Float>?) {
        guard rawDT.isFinite, rawDT > 0 else { return }
        looseSnow.beginFrame()
        refreshCornerWind()
        applySupportTransfers()
        applySnowReleases()
        let dt = min(rawDT, 0.05) // Never catch up a backlog after sleep, stalls, or resizing.
        elapsed += dt
        geometryAge += dt
        settleAge += dt
        if let cursor, cursor.x.isFinite, cursor.y.isFinite {
            if tool == .shovel {
                sweep(from: rawDT < 0.2 ? (previousCursor ?? cursor) : cursor, to: cursor, dt: dt)
            } else if rawDT < 0.2, let previousCursor {
                let delta = cursor - previousCursor
                if delta.x * delta.x + delta.y * delta.y > 0.25 {
                    sweep(from: previousCursor, to: cursor, dt: dt)
                }
            }
            previousCursor = cursor
        } else { previousCursor = nil }

        for drift in drifts { drift.accumulate(dt: dt, intensity: snowDensity) }
        if settleAge >= 0.1 {
            for drift in drifts { drift.settle() }
            settleAge = 0
            meshDirty = true
        }
        let desired = reducedMotion ? 0 : min(budget.flakes,
            Int(Float(budget.flakes) * min(1, snowDensity / Snowfall.flurry.density) * max(0, min(1, particleScale))))
        if flakes.count > desired { flakes.removeLast(flakes.count - desired) }
        while flakes.count < desired { flakes.append(newFlake(scattered: true)) }

        let wind = sin(elapsed * 0.23) * 7 + sin(elapsed * 0.071) * 5
        for i in flakes.indices {
            var particle = flakes[i]
            particle.phase += dt * 0.8
            if particle.phase > .pi * 2 { particle.phase -= .pi * 2 }
            let gust = SIMD2(wind + sin(particle.phase) * 9 + self.wind.velocity.x,
                             self.wind.velocity.y * 0.35)
            particle.velocity += gust
            let deposited = advanceParticle(&particle, dt: dt, recycleOnContact: true)
            particle.velocity -= gust
            if deposited || particle.position.y > size.y + 8 || particle.position.y < -40 {
                particle = newFlake(scattered: false)
            }
            if particle.position.x < -8 { particle.position.x = size.x + 4 }
            if particle.position.x > size.x + 8 { particle.position.x = -4 }
            flakes[i] = particle
        }
        let looseRevision = looseSnow.revision
        looseSnow.step(dt: dt, wind: self.wind.velocity) { [unowned self] from, to, mass in
            self.landGranularSnow(from: from, to: to, mass: mass)
        }
        if tool == .shovel, let cursor {
            sweep(from: cursor, to: cursor, dt: dt)
        }
        if looseRevision != looseSnow.revision { meshDirty = true; interactionDirty = true }
        if meshDirty && (geometryAge >= 0.1 || interactionDirty) { rebuildMesh() }
    }

}
