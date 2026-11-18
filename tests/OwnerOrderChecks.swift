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

        precondition(OwnerOrdering.normalizedOwner("  pony-factor  ") == "pony-factor")
        precondition(OwnerOrdering.normalizedOwner("not valid!") == nil)

        let mixedCase = OwnerOrdering.ordered(["blocktransfer", "AM-only", "am-only", "WhyDRS"],
                                              preferred: ["am-only", "AM-only", "WHYDRS", "blocktransfer"])
        precondition(mixedCase == ["AM-only", "WhyDRS", "blocktransfer"])
        precondition(OwnerOrdering.ordered(["AM-only", "am-only"], preferred: []) == ["AM-only"])

        print("PASS: organization ordering, drag placement, persistence order, new-owner append, owner validation")
    }
}
