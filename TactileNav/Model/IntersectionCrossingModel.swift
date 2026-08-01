//
//  IntersectionCrossingModel.swift
//  TactileNav
//
//  A four-way signalised intersection you judge by ear.
//
//  This models the actual technique blind travellers are taught: you do not cross when it
//  goes quiet, you cross with the **parallel surge** — the moment the traffic beside you,
//  running the same way you want to walk, pulls away from the line. That surge is your green.
//  Traffic sweeping left to right across your front is the cross street, and means wait.
//
//  So the simulation has to get three things right:
//    1. traffic on all four legs, not one lane, so parallel and perpendicular movement are
//       actually distinguishable;
//    2. a signal cycle that starts each green with a burst of vehicles accelerating together,
//       because a surge is what a listener recognises, not a single car;
//    3. vehicles that turn across the crosswalk during your walk phase — the moment that
//       injures people, and the one a quiet intersection never teaches you to expect.
//
//  Nothing here speaks. The whole point is that the ears do the work.
//

import CoreGraphics
import Foundation

// MARK: - Geometry

/// The demo intersection: Congress Street at High Street, downtown Portland.
///
/// This is the junction Congress Square is named for, and the same one you can explore by
/// touch on the map screen — so a demo can move from "feel where the streets run" straight to
/// "now stand on that corner and listen". Two four-lane primaries crossing at a real signal.
///
/// Bearings are the true OpenStreetMap bearings of the four legs (degrees clockwise from
/// north), read from the same extract the map screen uses.
enum DemoIntersection {

    static let name = "Congress Street at High Street"
    static let shortName = "Congress at High"

    /// Congress Street, running east-north-east and west-south-west.
    static let congressBearings: (outbound: Double, inbound: Double) = (43, 240)
    /// High Street, running north-north-west and south-south-east.
    static let highBearings: (outbound: Double, inbound: Double) = (320, 145)

    /// Where the listener stands and which way they face.
    ///
    /// On the corner, about to cross Congress Street, facing along High Street. That makes
    /// High Street the *parallel* street: when it surges, the walk signal is on.
    static let listenerFacing: Double = highBearings.outbound

    /// Half-width of each roadway in metres — four lanes at 3.3 m.
    static let roadHalfWidthM: Double = 4 * 3.3 / 2

    /// Clearance from the kerb line to where someone actually stands.
    static let kerbSetbackM: Double = 2.0

    /// Offset of a travel lane from the road centreline — the middle of the near two lanes.
    static let laneOffsetM: Double = 3.3

    /// A unit vector along a compass bearing, in world metres (+x east, +y north).
    static func direction(_ bearing: Double) -> CGPoint {
        let radians = bearing * .pi / 180
        return CGPoint(x: sin(radians), y: cos(radians))
    }

    /// Where the listener stands, in world metres from the intersection centre.
    ///
    /// On the *corner*, not in the road: back along High Street far enough to clear the
    /// Congress Street roadway, and off to one side far enough to clear the High Street
    /// roadway. Getting this right matters for more than the picture — every distance, pan
    /// and Doppler curve is measured from this point, so standing in the middle of the
    /// junction would put traffic on the wrong side of the listener.
    static let listenerPositionM: CGPoint = {
        let back = direction(highBearings.inbound)          // away from the crossing
        let across = direction(congressBearings.inbound)    // along Congress, to one side
        let backDistance = roadHalfWidthM + kerbSetbackM
        let sideDistance = roadHalfWidthM + kerbSetbackM
        return CGPoint(x: back.x * backDistance + across.x * sideDistance,
                       y: back.y * backDistance + across.y * sideDistance)
    }()

    /// Middle of the crossing the listener is about to use: straight ahead of them, at the
    /// centreline of Congress Street.
    static let crosswalkCenterM: CGPoint = {
        let forward = direction(highBearings.outbound)
        let distance = roadHalfWidthM + kerbSetbackM
        return CGPoint(x: listenerPositionM.x + forward.x * distance,
                       y: listenerPositionM.y + forward.y * distance)
    }()
}

// MARK: - Legs

/// One approach to the intersection.
enum IntersectionLeg: String, CaseIterable, Identifiable {
    case congressEast, congressWest, highNorth, highSouth

    var id: String { rawValue }

    /// Compass bearing of the leg, measured from the intersection centre outward.
    var bearing: Double {
        switch self {
        case .congressEast: return DemoIntersection.congressBearings.outbound
        case .congressWest: return DemoIntersection.congressBearings.inbound
        case .highNorth: return DemoIntersection.highBearings.outbound
        case .highSouth: return DemoIntersection.highBearings.inbound
        }
    }

    var street: String {
        switch self {
        case .congressEast, .congressWest: return "Congress Street"
        case .highNorth, .highSouth: return "High Street"
        }
    }

    var label: String {
        switch self {
        case .congressEast: return "Congress Street, east"
        case .congressWest: return "Congress Street, west"
        case .highNorth: return "High Street, north"
        case .highSouth: return "High Street, south"
        }
    }

    /// The phase during which this leg has a green light.
    var phase: SignalPhase.Movement {
        switch self {
        case .congressEast, .congressWest: return .congress
        case .highNorth, .highSouth: return .high
        }
    }

    /// The leg a vehicle arriving here departs along when it drives straight through.
    var opposite: IntersectionLeg {
        switch self {
        case .congressEast: return .congressWest
        case .congressWest: return .congressEast
        case .highNorth: return .highSouth
        case .highSouth: return .highNorth
        }
    }
}

// MARK: - Signal cycle

struct SignalPhase {
    enum Movement {
        /// Congress Street is green: traffic crosses in front of the listener. Do not walk.
        case congress
        /// High Street is green: traffic runs parallel to the listener's path. This is the
        /// surge that means walk.
        case high
    }

    enum Kind: Equatable {
        case green(Movement)
        /// Everything stopped between greens.
        case allRed
    }

    let kind: Kind
    let duration: TimeInterval

    /// A plausible urban cycle. The timings are modelled, not a feed from the city — there is
    /// no public real-time signal data for Portland — but the *structure* is what matters
    /// here: a long green, a short all-red, the other long green, another all-red.
    static let cycle: [SignalPhase] = [
        SignalPhase(kind: .green(.high), duration: 18),
        SignalPhase(kind: .allRed, duration: 4),
        SignalPhase(kind: .green(.congress), duration: 18),
        SignalPhase(kind: .allRed, duration: 4),
    ]

    static var cycleLength: TimeInterval { cycle.reduce(0) { $0 + $1.duration } }

    /// Which phase the cycle is in, and how far through it, at a given elapsed time.
    static func phase(at elapsed: TimeInterval) -> (phase: SignalPhase, progress: Double, index: Int) {
        var remaining = elapsed.truncatingRemainder(dividingBy: cycleLength)
        for (index, phase) in cycle.enumerated() {
            if remaining < phase.duration {
                return (phase, remaining / phase.duration, index)
            }
            remaining -= phase.duration
        }
        return (cycle[0], 0, 0)
    }

    /// Whether it is safe to start crossing Congress Street.
    ///
    /// Only at the start of the parallel green: you step off with the surge, not part-way
    /// through it, or the clearance interval runs out mid-crossing.
    var isWalkPhase: Bool { kind == .green(.high) }
}

// MARK: - Vehicles

struct SimulatedVehicle: Identifiable {
    let id = UUID()
    let type: TrafficAudioEngine.VehicleType
    let entryLeg: IntersectionLeg
    let exitLeg: IntersectionLeg
    let speedMps: Double
    /// Seconds since this vehicle entered the simulation.
    var age: TimeInterval = 0
    /// Voice index held in the audio engine, if one was available.
    var voice: Int?

    /// Turning across the listener's crosswalk — the highest-risk movement during a walk
    /// phase, and the one that is hardest to hear coming because the vehicle never gets loud
    /// until it is already on top of you.
    var isTurning: Bool { exitLeg != entryLeg.opposite }

    /// Distance travelled along its path.
    var travelled: Double { speedMps * age }
}

// MARK: - The simulation

/// Runs the signal cycle and the traffic on it. Holds no audio itself — the view drives the
/// engine from `vehicles` each tick — so this stays plain, testable value logic.
@MainActor
final class IntersectionCrossingModel {

    /// Metres of approach and departure either side of the intersection.
    static let legLengthM: Double = 55

    private(set) var vehicles: [SimulatedVehicle] = []
    private(set) var elapsed: TimeInterval = 0

    /// What the traffic is made of. An all-electric surge is the demonstration that the
    /// technique itself can fail: the cue a traveller depends on is barely there.
    var fleet: Fleet = .gasoline

    enum Fleet: String, CaseIterable, Identifiable {
        case gasoline, electric, mixed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gasoline: return "Gas"
            case .electric: return "Electric"
            case .mixed: return "Mixed"
            }
        }
        var detail: String {
            switch self {
            case .gasoline:
                return "Combustion traffic. The surge at the start of a green is clearly audible."
            case .electric:
                return "All-electric traffic, under 45 dBA at low speed. The surge you would "
                     + "normally step off with is barely there."
            case .mixed:
                return "A realistic mix. Some vehicles in the surge are almost silent."
            }
        }
        func pick(_ random: inout SystemRandomNumberGenerator) -> TrafficAudioEngine.VehicleType {
            switch self {
            case .gasoline: return Bool.random(using: &random) ? .car : .truck
            case .electric: return .ev
            case .mixed: return Int.random(in: 0..<3, using: &random) == 0 ? .ev : .car
            }
        }
    }

    private var random = SystemRandomNumberGenerator()
    private var nextSpawn: TimeInterval = 0
    private var lastPhaseIndex = -1

    var currentPhase: SignalPhase { SignalPhase.phase(at: elapsed).phase }

    func reset() {
        vehicles.removeAll()
        elapsed = 0
        nextSpawn = 0
        lastPhaseIndex = -1
    }

    /// Advance the world. Returns the vehicles that just left, so their voices can be freed.
    func advance(by delta: TimeInterval) -> [SimulatedVehicle] {
        elapsed += delta

        let (phase, _, index) = SignalPhase.phase(at: elapsed)

        // A green opens with several vehicles pulling away together. That collective surge is
        // the audible event a traveller actually keys on — one car alone is ambiguous.
        if index != lastPhaseIndex {
            lastPhaseIndex = index
            if case .green(let movement) = phase.kind {
                for _ in 0..<Int.random(in: 2...3, using: &random) {
                    spawn(movement: movement, atQueueFront: true)
                }
                nextSpawn = elapsed + Double.random(in: 1.5...3.0, using: &random)
            }
        }

        // Then a thinner trickle for the rest of the green.
        if case .green(let movement) = phase.kind, elapsed >= nextSpawn {
            spawn(movement: movement, atQueueFront: false)
            nextSpawn = elapsed + Double.random(in: 1.8...3.5, using: &random)
        }

        let total = Self.legLengthM * 2
        var departed: [SimulatedVehicle] = []
        for index in vehicles.indices { vehicles[index].age += delta }
        vehicles.removeAll { vehicle in
            let gone = vehicle.travelled > total
            if gone { departed.append(vehicle) }
            return gone
        }
        return departed
    }

    /// Mutate every live vehicle in place — used to attach voices and drive the audio without
    /// copying the array back and forth.
    func updateEachVehicle(_ body: (inout SimulatedVehicle) -> Void) {
        for index in vehicles.indices { body(&vehicles[index]) }
    }

    private func spawn(movement: SignalPhase.Movement, atQueueFront: Bool) {
        guard vehicles.count < TrafficAudioEngine.voiceCount else { return }

        let legs = IntersectionLeg.allCases.filter { $0.phase == movement }
        guard let entry = legs.randomElement(using: &random) else { return }

        // During the parallel green, some vehicles turn across the crosswalk.
        var exit = entry.opposite
        if movement == .high, Int.random(in: 0..<4, using: &random) == 0 {
            let turns = IntersectionLeg.allCases.filter { $0.phase == .congress }
            exit = turns.randomElement(using: &random) ?? exit
        }

        // Vehicles at the front of a queue accelerate away; later ones are already rolling.
        let speedMph = atQueueFront
            ? Double.random(in: 14...22, using: &random)
            : Double.random(in: 20...30, using: &random)

        vehicles.append(SimulatedVehicle(
            type: fleet.pick(&random),
            entryLeg: entry,
            exitLeg: exit,
            speedMps: speedMph * 0.44704
        ))
    }
}

// MARK: - Placing a vehicle relative to the listener

extension SimulatedVehicle {

    /// Position in metres in the listener's own frame: +x to their right, +y straight ahead.
    ///
    /// Everything the ear uses — which side, how far, closing or receding — falls out of this
    /// one vector, so the audio and the on-screen dot can never disagree.
    func position(legLength: Double) -> CGPoint {
        let world = worldPosition(legLength: legLength)

        // The listener stands on the corner, facing up the parallel street. Rotate the world
        // into that frame so left and right mean what they should.
        let stand = DemoIntersection.listenerPositionM
        let dx = Double(world.x - stand.x)
        let dy = Double(world.y - stand.y)

        let facing = DemoIntersection.listenerFacing * .pi / 180
        let forward = dx * sin(facing) + dy * cos(facing)
        let right = dx * cos(facing) - dy * sin(facing)
        return CGPoint(x: right, y: forward)
    }

    /// Position in world metres from the intersection centre, +x east, +y north.
    ///
    /// Vehicles keep right rather than running down the centreline. That is not cosmetic: it
    /// is what makes the near lane audibly closer than the far one, and it is what puts a
    /// turning vehicle on a curve through the corner instead of a kink through a single
    /// point. Without it every movement passes the listener at the same distance and the
    /// intersection has nothing to tell them apart by.
    func worldPosition(legLength: Double) -> CGPoint {
        let total = legLength * 2
        let progress = min(max(travelled / total, 0), 1)
        let junction = DemoIntersection.roadHalfWidthM

        // Heading while approaching (down the entry leg toward the centre) and while leaving.
        let entryHeading = entryLeg.bearing + 180
        let exitHeading = exitLeg.bearing

        let approachEnd = Self.lanePoint(leg: entryLeg, heading: entryHeading,
                                         distanceFromCentre: junction)
        let departStart = Self.lanePoint(leg: exitLeg, heading: exitHeading,
                                         distanceFromCentre: junction)

        // Split the run: approach, the turn or crossing through the box, then departure.
        let approachSpan = (legLength - junction) / total
        let junctionSpan = (junction * 2) / total

        if progress < approachSpan {
            let t = progress / approachSpan
            let start = Self.lanePoint(leg: entryLeg, heading: entryHeading,
                                       distanceFromCentre: legLength)
            return Self.lerp(start, approachEnd, t)
        }
        if progress < approachSpan + junctionSpan {
            let t = (progress - approachSpan) / junctionSpan
            // Quadratic curve through the centre: a straight-through movement stays straight
            // because its two lane lines are collinear, and a turn sweeps the corner.
            return Self.quadratic(approachEnd, .zero, departStart, t)
        }
        let t = (progress - approachSpan - junctionSpan) / max(1 - approachSpan - junctionSpan, 0.0001)
        let end = Self.lanePoint(leg: exitLeg, heading: exitHeading, distanceFromCentre: legLength)
        return Self.lerp(departStart, end, t)
    }

    /// A point in the right-hand travel lane of a leg, for a vehicle moving along `heading`.
    private static func lanePoint(leg: IntersectionLeg, heading: Double,
                                  distanceFromCentre: Double) -> CGPoint {
        let centreline = DemoIntersection.direction(leg.bearing)
        let travel = DemoIntersection.direction(heading)
        // Right of the direction of travel.
        let right = CGPoint(x: travel.y, y: -travel.x)
        let offset = DemoIntersection.laneOffsetM
        return CGPoint(x: centreline.x * distanceFromCentre + right.x * offset,
                       y: centreline.y * distanceFromCentre + right.y * offset)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func quadratic(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
    }
}
