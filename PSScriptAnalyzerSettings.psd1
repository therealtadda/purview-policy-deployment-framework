@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Commands write plans and evidence files, not system state; apply is gated by plan hash and approval tier.
        'PSUseShouldProcessForStateChangingFunctions'
        # Provider script blocks share a fixed parameter signature, so some parameters are intentionally unused.
        'PSReviewUnusedParameter'
        # The CLI and identity scripts are interactive operator tools that print progress.
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingPositionalParameters'
    )
}
