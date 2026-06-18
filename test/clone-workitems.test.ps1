# Execute clone-workitems.ps1 with default parameters
& "$PSScriptRoot\..\clone-workitems.ps1" `
    -ConfigPath "$PSScriptRoot\test-config.json" `
    -OutputDir "$PSScriptRoot\output"