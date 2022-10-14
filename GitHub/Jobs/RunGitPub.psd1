@{
    "runs-on" = "ubuntu-latest"    
    if = '${{ success() }}'
    steps = @(
        @{
            name = 'Check out repository'
            uses = 'actions/checkout@v2'
        }
        @{
            name = 'Use GitPub Action'
            uses = 'StartAutomating/GitPub@main'
            id  = 'GitPub'
            with = @{
                TargetBranch = 'edits-$([DateTime]::Now.ToString("r").Replace(":","-").Replace(" ", ""))'
                CommitMessage = 'Posting with GitPub [skip ci]'
                PublishParameters = @'
{
    "Get-GitPubIssue": {
        "UserName": '${{github.repository_owner}}',
        "Repository": "PipeScript"
    },
    "Get-GitPubRelease": {
        "UserName": '${{github.repository_owner}}',
        "Repository": "PipeScript"
    },
    "Publish-GitPubJekyll": {
        "OutputPath": "docs/_posts"
    }
}
'@                    
            }
        }
    )
}