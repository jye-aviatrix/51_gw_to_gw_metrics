@{
    RootModule        = 'AviatrixCopilot.psm1'
    ModuleVersion     = '1.3.0'
    GUID              = '480402bf-5711-459d-80d9-d0f8f56f0c2b'
    Author            = 'Jun Ye'
    Description       = 'Log in to Aviatrix CoPilot using a local user account and query gateway interface performance stats.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Connect-AviatrixCopilot',
        'Disconnect-AviatrixCopilot',
        'Get-AviatrixCopilotSession',
        'Get-AviatrixCopilotGatewayInterface',
        'Get-AviatrixCopilotGatewayInterfaceStats',
        'Get-AviatrixCopilotGatewayPairTunnelStats',
        'Get-AviatrixCopilotSpokeTransitAttachment',
        'Get-AviatrixCopilotTransitPeering',
        'Export-AviatrixCopilotConnectionMetric'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
