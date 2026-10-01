import Foundation

@main struct OwnerOrderChecks {
    static func main() {
        let initial = OwnerOrdering.ordered(["zeta", "alpha", "beta"], preferred: [])
        precondition(initial == ["alpha", "beta", "zeta"])

        let movedLeft = OwnerOrdering.moving("zeta", relativeTo: "alpha", after: false,
                                             owners: initial, preferred: [])
        precondition(movedLeft == ["zeta", "alpha", "beta"])
        precondition(OwnerOrdering.ordered(initial, preferred: movedLeft) == movedLeft)

        let withNewOwner = OwnerOrdering.ordered(["zeta", "alpha", "beta", "gamma"], preferred: movedLeft)
        precondition(withNewOwner == ["zeta", "alpha", "beta", "gamma"])

        let movedRight = OwnerOrdering.moving("zeta", relativeTo: "beta", after: true,
                                              owners: withNewOwner, preferred: movedLeft)
        precondition(movedRight == ["alpha", "beta", "zeta", "gamma"])

        print("PASS: organization ordering, drag placement, persistence order, new-owner append")
    }
}
