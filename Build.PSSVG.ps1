#Requires -Module PipeScript
#Requires -Module Irregular
#requires -Module PSDevOps

<#
.SYNOPSIS
    Generates PSSVG
.DESCRIPTION
    Generates PSSVG, a module for creating 2d images with PowerShell.

    PSSVG allows you to create Scalable Vector Graphics using PowerShell commands.

    To make these commands, we will read the Markdown source for the Mozilla Developer Network's documentation on SVG.
.NOTES
    This script should build several scripts, each of which correlate to a given element.  Deprecated elements will be skipped.

    Most elements have a partial list of attributes followed by a series of common attribute groups.

    As such, we have to do a few fairly complex things here:

    1. Get the list of all elements
    2. Get the list of all attributes (and all of their metadata)
    3. Get the defined attribute groups
    4. Parse the documentation for each element
    5. Expand out the grouped attributes defined for each element
    6. Take the combined content and generate a function

    This script uses Irregular to assist in the first several steps.
    It then uses PipeScript to create the final function.
.LINK
    https://github.com/mdn/content/blob/main/LICENSE.md
#>

# Initialize some collections for us to use:

# * The SVGCommonAttributes
if (-not $svgCommonAttributes) {
    $svgCommonAttributes = [Ordered]@{}    
}

# * Any SavedMarkdown files (so we can save time and bandwidth)
if (-not $savedMarkdown) {
    $savedMarkdown = [Ordered]@{}
}

# * If any markdown was not found (to avoid repeated failure)
if (-not $markdownNotFound) {
    $markdownNotFound = [Ordered]@{}
}

# * The combined metadata about each element
if (-not $svgElementData) {
    $svgElementData = [Ordered]@{}
}

# If we had a GITHUB_TOKEN, use it as $ghp
if ($env:GITHUB_TOKEN) {
    $ghp = $env:GITHUB_TOKEN
}

if (-not $ghp) {
    Write-Error "Must have defined a GitHub Personal Access Token in `$ghp"
    return
}

# If we don't know the list of elements
if (-not $svgElements) {
    # we can go to the repo and get the JSON.
    $svgData = Invoke-GitHubRestAPI 'https://api.github.com/repos/mdn/content/contents/files/jsondata/SVGData.json' -PersonalAccessToken $ghp
    $svgElements = [Text.Encoding]::utf8.getString([Convert]::FromBase64String($svgData.content)) | ConvertFrom-Json
}

$findSvgElement = [Regex]::new("\{\{SVGElement\(['`"](?<e>[^'`"]+)")
$findSvgAttr = [Regex]::new("\{\{SVGAttr\(['`"](?<a>[^'`"]+)")

function ConvertSVGMetadataToParameterAttribute {
    param([Parameter(ValueFromPipeline,Position=0)][string]$EdiValue)
    $hadNumbers = $false
    $hadUri     = $false
    $hadColor   = $false
    $hadUnknown = $false
    if ($ediValue -notmatch '\|') {
        if ($ediValue -match '\<(?<t>[^\>])>') {
            if ($matches.t -as [type]) {
                "[$($matches.t)]"
            }
        }
        return
    }
    $validSet = @(foreach ($validValue in $ediValue -split '\|' -replace '^\s{0,}' -replace '\s{0,}$') {
        if ($validValue -as [int] -or $validValue -match 'number') {
            $hadNumbers = $true
        } 
        elseif ($validValue -match 'uri') {
            $hadUri = $true
        }
        elseif ($ediValue -match 'length') {
            $hadNumbers = $true
        }
        elseif ($ediValue -match 'color') {
            $hadColor = $true
        }
        elseif ($ediValue -match '\<.+\>') {
            $hadUnknown = $true
        }
        else {
            $validValue
        }                                
    }) -join "','"
    if ($hadNumbers) {
        "[ValidatePattern('(?>$($validSet -split "','" -join '|')|\d+)')]"
    }
    elseif ($hadUri -and $validSet) {
        "[ValidateScript({`$_ -in '$validSet' -or `$_ -as [uri]})]"
    }
    elseif ($hadColor) {
        "[ValidateScript({`$_ -in '$validSet' -or `$_ -match '\#[0-9a-f]{3}' -or `$_ -match '\#[0-9a-f]{6}' -or `$_ -notmatch '\W'})]"
    }
    elseif ($validSet -and -not $hadUnknown) {
        "[ValidateSet('$validSet')]"
    }     
}

function ImportSvgAttribute {
    param(
    [Parameter(ValueFromPipeline,Position=0)]
    [uri]
    $SVGAttributeUri
    )
    $elementOrSetName = $SVGAttributeUri.Segments[-2] -replace '^/' -replace '/$'
    if (-not $savedMarkdown["$SVGAttributeUri"]) {
        $savedMarkdown["$SVGAttributeUri"] = [Text.Encoding]::utf8.getString([Convert]::FromBase64String(
            $(try {
                Invoke-GitHubRestApi -Uri $SVGAttributeUri -ErrorAction SilentlyContinue -PersonalAccessToken $ghp
            } catch {
                Write-Warning "$SVGAttributeUri : $_"                
            }).Content
        ))
    }
    $elementMarkdown = $savedMarkdown["$SVGAttributeUri"]
    if (-not $elementMarkdown) {
        Write-Verbose "Did not get content for $elementOrSetName"
        return
    }
    $replaceMDNContent = "\{\{\s{0,}(?>$(@('Glossary', 'domxref', 'HTTPMethod', 'htmlelement','svgelement', 'svgattr','htmlattrxref','cssxref')  -join '|')[^\)]{0,})\(" + 
        '["''](?<s>[^"'']+)["'']\)\s{0,}\}\}'
    
    $start, $end = 0, 0
    $globalAttrStart, $globalAttrEnd = 0, 0 
    $exampleStart, $exampleEnd = 0, 0
    $svgRefIndex = $elementMarkdown.IndexOf("{{SVGRef}}") 
    $animationAttributeStart, $animationAttributeEnd = 0, 0
    $elementDescription = ''
    $groupedAttributes = @()
    foreach ($heading in $elementMarkdown | ?<Markdown_Heading>) {
        $headingName = $heading.Groups["HeadingName"].Value
        if ($svgRefIndex -ge 0 -and -not $elementDescription -and $heading.Index -ge $svgRefIndex) {
            $svgRefIndex += + "{{SVGRef}}".Length
            $elementDescription = 
                $elementMarkdown.Substring($svgRefIndex, $heading.Index - $svgRefIndex) -replace $replaceMDNContent, '`${s}`' | 
                ?<Markdown_Link> -ReplaceEvaluator {
                    param($match)
                    "[$($match.Groups["Text"])](https://developer.mozilla.org$($match.Groups['Uri']))"
                }                
        }
        if ($headingName -eq 'Example') {
            $exampleStart = $heading.Groups["HeadingName"].Index
            $exampleEnd = $heading.NextMatch().Index
        }
        if ($headingName -eq 'Attributes' -or $headingName -eq 'Specific attributes') {
            $start = $heading.Index
            $end = $heading.NextMatch().Index            
        }
        if ($headingName -match $trailingAttributes -and $attributeGroups[$headingName -replace $trailingAttributes -replace '\s']) {
            $attributeGroupName = $headingName -replace $trailingAttributes -replace '\s'
            $groupedAttributes += [PSCustomObject]@{
                Name  = $attributeGroupName
                Group = $attributeGroups[$attributeGroupName]
            }
        }
        else {
            if ($headingName -eq 'Animation Attributes') {
                $animationAttributeStart =$heading.Index
                $animationAttributeEnd = $heading.NextMatch().Index
            }
            
            if ($heading.Groups["HeadingName"].Value -eq 'Global attributes') {
                $globalAttrStart = $heading.Index
                $globalAttrEnd   = $heading.NextMatch().Index            
            }
        }            
    }
    
    $elementAttributeContent = $elementMarkdown.Substring($start, $end - $start) -replace $replaceMDNContent, '${s}'
    $elementAttributes = $elementAttributeContent | ImportSvgElementAttribute
    $globalAttributes  = @()
    if ($globalAttrStart) {
        $elementGlobalAttributeContent = 
            $elementMarkdown.Substring($globalAttrStart, $globalAttrEnd - $globalAttrStart) -replace $replaceMDNContent, '${s}'
        
        $elementGlobalAttributeContent | 
            ?<Markdown_Link> -extract | 
            Where-Object Text -match $trailingAttributes |             
            ForEach-Object {                
                $attributeGroupName = $_.Text -replace $trailingAttributes -replace '\s' -replace 'Styling', 'Style'
                if ($attributeGroups[$attributeGroupName]) {
                    $groupedAttributes += [PSCustomObject]@{
                        Name  = $attributeGroupName
                        Group = $attributeGroups[$attributeGroupName]
                    }
                }
            }
    }
        
    $allAttributeHelp = [Ordered]@{} + $elementAttributes.Help
    $allAttributeData = [Ordered]@{} + $elementAttributes.Data
    $allAttributeNames = @() + $elementAttributes.AttributeNames
    if ($groupedAttributes) {
        foreach ($attrInGroup in $groupedAttributes.Group) {
            if ($attrMetadata[$attrInGroup]) {
                if (-not $allAttributeData[$attrInGroup]) {
                    $allAttributeData += @{
                        $attrInGroup = $attrMetadata[$attrInGroup].Properties
                    }
                }
                if (-not $allAttributeHelp[$attrInGroup]) {
                    $allAttributeHelp += @{
                        $attrInGroup = $attrMetadata[$attrInGroup].Description
                    }
                }                  
                                
                $allAttributeNames += $attrInGroup
            }
        }
    }
    $elementContentInfo = $svgElements.elements.$elementOrSetName.content           
    [PSCustomObject][Ordered]@{
        Name            = $elementOrSetName
        Description     = $elementDescription
        AttributeNames  = $allAttributeNames
        Help            = $allAttributeHelp
        Data            = $allAttributeData
        Content         = $elementContentInfo
        SourceUri       = $SVGAttributeUri
    }
}

function ImportSvgElementAttribute {
    param(
    [Parameter(Position=0,ValueFromPipeline)]
    [string]
    $elementAttributeContent
    )
    process {
        $elementAttributeLines = $elementAttributeContent -split "(?>\r\n|\n)"
        $attributeName = ''
        
        $attributeLine     = '^-\s'
        $attributeHelpLine = '^\s+-\s\:'
        $attributeDataLine = '^\s+_'
        $quotedString  = [Regex]::new(@'
(?<=["'])[^"']*?(?=["'])
'@, 'IgnoreCase,IgnorePatternWhitespace')
        $attributeHelp = [Ordered]@{}
        $attributeData = [Ordered]@{}
        $attributeNames = @()
        foreach ($elementAttributeLine in $elementAttributeLines) {
            if ($elementAttributeLine -match $attributeLine) {
                $attributeName = $quotedString.Matches($elementAttributeLine) |
                    Select-Object -First 1 |
                    ForEach-Object { $_.ToString()}
                if (-not $attributeName) {
                    $attributeName = $elementAttributeLine -replace $attributeLine
                }
                if ($attributeName){
                    if ($attributeName -match ',' -and $elementAttributeLine -match ':') {
                        $nameList, $description = $elementAttributeLine -replace $attributeLine -split ':', 2
                        $attributeName = @($nameList -split ',' -replace '^\s{0,}' -replace '\s{0,}$')
                        $attributeNames += $attributeName
                        $attributeHelp[$attributeName] = $description
                    } else {
                        $attributeName = @($attributeName -split ' ')[0] -replace '\*' -replace '\:$'
                    
                        $attributeNames += $attributeName
                    }                    
                }
                if ($attrMetadata[$attributeName]) {
                    $attributeData[$attributeName] = $attrMetadata[$attributeName].Properties
                }
            }
            elseif ($attributeName -and $elementAttributeLine -match $attributeHelpLine) {            
                $attributeHelp[$attributeName] = $elementAttributeLine -replace $attributeHelpLine                
            }            
        }
        [PSCustomObject][Ordered]@{
            Help = $attributeHelp
            Data = $attributeData
            AttributeNames = $attributeNames
        }
    }
}

function InitializeSvgAttributeData {
    $attributeListUri = "https://api.github.com/repos/mdn/content/contents/files/en-us/web/svg/attribute/index.md"
    if (-not $savedMarkdown[$attributeListUri]) {
        $savedMarkdown[$attributeListUri] = [Text.Encoding]::utf8.getString([Convert]::FromBase64String(
                $(try {
                    Invoke-GitHubRestApi -Uri $attributeListUri -ErrorAction SilentlyContinue -PersonalAccessToken $ghp
                } catch {
                    Write-Warning "$SVGAttributeUri : $_"                
                }).Content
            ))
    }
    
    $attributeListMarkdown = $savedMarkdown[$attributeListUri]
    $headingList         = @($attributeListMarkdown | ?<Markdown_Heading> -Split -IncludeMatch)
    $attributeGroups     = [Ordered]@{}
    $attributeGroupsText = [Ordered]@{}
    $trailingAttributes  = '\s{0,}attributes\s{0,}$'
    for ($hln = 0; $hln -lt $headingList.Count; $hln++) {
        if ($headingList[$hln] -match $trailingAttributes) {
            $attributeGroupName = ($headingList[$hln] -replace '^[\s\r\n]{0,}\#{0,}' -replace $trailingAttributes).Trim()
            $attributeGroupContent = $headingList[$hln + 1]    
            $attributeGroups[$attributeGroupName] = @(foreach ($attrMatch in $findSvgAttr.Matches($attributeGroupContent)) {            
                $attrMatch.Groups["a"].Value
            })
            $attributeGroupsText[$attributeGroupName] = $attributeGroupContent
        }
    }
    foreach ($groupWithSubGroups in 'Generic', 'Animation') {
        $genericGroupsText = $attributeGroupsText.$groupWithSubGroups
        $genericGroupsList = @($genericGroupsText | ?<Markdown_List> -Split -IncludeMatch)
        for ($genericIndex = 0; $genericIndex -lt $genericGroupsList.Length; $genericIndex++) {
            if ($genericGroupsList[$genericIndex] -match $trailingAttributes) {
                $attributeGroupName = ($genericGroupsList[$genericIndex] -replace '^[\s-]+' -replace $trailingAttributes -replace '\s')            
                
                for ($endGenericIndex = $genericIndex + 1; $endGenericIndex -lt $genericGroupsList.Length; $endGenericIndex++) {
                    if ($genericGroupsList[$endGenericIndex] -match $trailingAttributes) {
                        $endGenericIndex--
                        break
                    }
                }
                $attributeGroups[$attributeGroupName] =
                    @(foreach ($attrMatch in $findSvgAttr.Matches("$($genericGroupsList[$genericIndex..$endGenericIndex])")) {            
                        $attrMatch.Groups["a"].Value
                    })
            }
        }
    }
    $null = $null
    
    
    
    $attrsFound = [Ordered]@{}
    foreach ($match in $findSvgAttr.Matches($savedMarkdown[$attributeListUri])) {
        $attrName = $match.Groups["a"].Value
        if (-not $attrsFound[$attrName]) {
            $attrUriPart = $attrName.ToLower() -replace '\:', '_colon_'
            $attrsFound[$attrName] = "https://api.github.com/repos/mdn/content/contents/files/en-us/web/svg/attribute/$attrUriPart/index.md"
        }    
    }
    
    $findSvgElement = [Regex]::new("\{\{SVGElement\(['`"](?<e>[^'`"]+)")
    $attrMetadata   = [Ordered]@{}
    
    foreach ($attrKv in $attrsFound.GetEnumerator()) {
        $attrUri = $attrKv.Value
        if (-not $savedMarkdown[$attrUri] -and -not $markdownNotFound[$attrUri]) {
            $savedMarkdown[$attrUri] = [Text.Encoding]::utf8.getString([Convert]::FromBase64String(
                $(try {
                    $err = $null
                    Invoke-GitHubRestApi -Uri $attrUri -ErrorAction SilentlyContinue -PersonalAccessToken $ghp -ErrorVariable err
                    if ($err -and $err -like '*404*') {
                        $markdownNotFound[$attrUri] = $true
                    }
                } catch {
                    Write-Warning "$SVGAttributeUri : $_"                
                }).Content
            ))
        } elseif ($markdownNotFound[$attrUri]) {
            $null = $null
        }
    
        if (-not $savedMarkdown[$attrUri]) {
            continue
        }
    
        $attributeTables   = @($savedMarkdown[$attrUri] | ?<HTML_StartOrEndTag> -Tag table)
        $attributeProperties = [Ordered]@{}
        for ($ati = 0; $ati -lt $attributeTables.Count; $ati++) {
            if ($attributeTables[$ati] -match 'properties') {
                $attrTable = 
                    $savedMarkdown[$attrUri].Substring(
                        $attributeTables[$ati].Index,  $attributeTables[$ati + 1].Index + $attributeTables[$ati + 1].Length - $attributeTables[$ati].Index
                    )
                $attrTableXml = $attrTable -as [xml]
                $tableRows = @($attrTableXml.table.tbody.tr)
                $tableKeys = @($tableRows.th.'#text')                
                
                for ($tri = 0 ; $tri -lt $tableKeys.Length; $tri++) {
                    $tableRowData = $tableRows[$tri].td
                    if (-not $tableKeys[$tri])  { continue }
                    $attributeProperties[$tableKeys[$tri]] = 
                        if ($tableRowData -is [string]) {
                            if ($tableRowData -eq 'yes') {
                                $true
                            }
                            elseif ($tableRowData -eq 'no') {
                                $false
                            }
                            else {
                                $tableRowData
                            }
                        } elseif ($tableRowData) {
                            (@(foreach ($innerText in $tableRowData.InnerText) {
                                "$innerText" -split '(?>\r\n|\n)' -replace '^\s{1,}', ' ' -replace '\s{1,}$'
                            }) -join '').Trim()
                        }
                }
                if ($attributeProperties['Default value'] -eq 'None') {
                    $attributeProperties.Remove('Default Value')
                }
                break
            }
    
        }
        
        $headingList       = $savedMarkdown[$attrUri] | ?<Markdown_Heading> -Split -IncludeMatch
        $replaceMDNContent = "\{\{\s{0,}(?>$(@('Glossary', 'domxref', 'HTTPMethod', 'htmlelement','svgelement', 'svgattr','htmlattrxref')  -join '|'))\(" + 
        '["''](?<s>[^"'']+)["'']\)\s{0,}\}\}'    
        
        $attrMetadata[$attrKv.key] = [PSCustomObject]@{
            Name = $attrKv.Key
            Elements = @(
                foreach ($elementMatch in $findSvgElement.Matches($savedMarkdown[$attrUri])) {
                    $elementMatch.Groups["e"].Value
                }
            )
            Description = $(
                foreach ($heading in $headingList) {
                    if ($heading -match '\{\{SVGRef\}\}') {
                        $heading -replace '\{\{SVGRef\}\}' -replace $replaceMDNContent, '${s}'
                        break
                    }
                }
            )
            Properties = $attributeProperties
        }
    }    
}

. InitializeSvgAttributeData


$eventAttributeListUri = "https://api.github.com/repos/mdn/content/contents/files/en-us/web/svg/attribute/events/index.md"
if (-not $savedMarkdown[$eventAttributeListUri]) {
    $savedMarkdown[$eventAttributeListUri] = [Text.Encoding]::utf8.getString([Convert]::FromBase64String(
            $(try {
                Invoke-GitHubRestApi -Uri $eventAttributeListUri -ErrorAction SilentlyContinue -PersonalAccessToken $ghp
            } catch {
                Write-Warning "$_"
            }).Content
        ))
}


$c, $t, $id = 0, @($svgElements.elements.psobject.properties).Length, (Get-Random)
foreach ($svgElement in $svgElements.elements.psobject.properties) {
    $elementName = $svgElement.Name
    $elementData = $svgElement.Value
    $c++
    Write-Progress "Getting Element Data" "$elementName " -Id $id -PercentComplete ($c * 100 / $t)
    
    if (-not $svgElementData[$elementName]) {
        $elementAttributes = 
            "https://api.github.com/repos/mdn/content/contents/files/en-us/web/svg/element/$($elementName.ToLower())/index.md" | 
                ImportSvgAttribute
    
        $svgElementData[$elementName] = $elementAttributes
    }
}


$examplesRoot = Join-Path $PSScriptRoot Examples


foreach ($elementKV in $svgElementData.GetEnumerator()) {
    $docsLink = "https://pssvg.start-automating.com/SVG.$($elementKV.Key)"
    $mdnLink  = "https://developer.mozilla.org/" + (@($elementKV.Value.SourceUri -split 'files/')[1] -replace 'en-us', 'en-US' -replace 'index.md$')
    if (-not $elementKV.Value) { continue }

    $newPipeScriptSplat = @{
        Synopsis    = "Creates SVG $($elementKV.Key) elements"
        Description = $elementKV.Value.Description.Trim()
        Link = $docsLink, $mdnLink
    }
    $relevantExampleFiles = Get-ChildItem -Filter *.ps1 -Path $examplesRoot |
        Select-String "\<svg.$($elementKv.Key)\>" | 
        Select-Object -ExpandProperty Path
    if ($relevantExampleFiles) {        
        $newPipeScriptSplat.Example = @(
            foreach ($exampleFile in $relevantExampleFiles) {
                ((Get-Content -Raw $exampleFile) -replace '\#requires -Module PSSVG' -replace '\s-OutputPath(?:.|\s){0,}?(?=\z|$)').Trim()
            }
        )        
    }


    if ($newPipeScriptSplat.Description -match 'The table below') {
        $newPipeScriptSplat.Description = @($newPipeScriptSplat.Description -split "The table below")[0]
    }

    if ($newPipeScriptSplat.Description -match '\{\{deprecated_header\}\}') {
        continue
    }
    
    $parameters = [Ordered]@{}

    if ($elementKV.Value.Content) {
        $content = $elementKV.Value.Content        
        $parameters.Content = @(
            "# The Contents of the $($elementKv.Key) element"
            if ($content.Description -eq 'characterDataElementsInAnyOrder') {
                "[Reflection.AssemblyMetaData('SVG.IsCData', `$$true)]"
                "[string]"
            }
            "[Parameter(Position=0,ValueFromPipelineByPropertyName)]"
            "[Alias('InputObject','Text', 'InnerText', 'Contents')]"
            '$Content'
        )        
    }
    
    $parameters['Data'] = @(
        "# A dictionary containing data.  This data will be embedded in data- attributes."
        "[Collections.IDictionary]"
        "[Parameter(ValueFromPipelineByPropertyName)]"
        '$Data'
    )
    
    foreach ($attrName in $elementKV.Value.AttributeNames) {
        $paramName = [regex]::Replace($attrName, '\W(?<w>\w+)', {
            param($match)
            $match.Groups['w'].Value.Substring(0,1).ToUpper() + 
                $match.Groups['w'].Value.Substring(1)
        })        
        $paramName = $paramName.Substring(0,1).ToUpper() + $paramName.Substring(1)
        $paramMetadata = $attrMetadata[$attrName]
        $paramIsDeprecated = $false
        $parameters[$paramName ] = @(
            $attrHelp = $elementKv.Value.Help.$attrName
          
            $paramIsDeprecated = $attrHelp -match '\{\{Deprecated_Header\}\}'
            $attrHelp = $attrHelp -replace $replaceMDNContent, '${s}' -replace '\{\{Deprecated_Header\}\}' -replace '^[\s\r\n]{0,}' -replace '[\s\r\n]{0,}$'
                
            if ($attrHelp -match 'You can use this attribute with the following SVG elements') {
                $attrHelp = @($attrHelp -split "You can use this attribute with the following SVG elements:[\s\r\n]")[0]
            }            

            foreach ($line in $attrHelp -split '(?>\r\n|\n)') {
                $line = $line.Trim()
                if ($line) {                 
                    $line = $line | ?<Markdown_Link> -ReplaceEvaluator {
                        param($match)
                        "[$($match.Groups["Text"])](https://developer.mozilla.org$($match.Groups['Uri']))"
                    }                
                }
                                
                "# " + $line
            }
            "[Parameter(ValueFromPipelineByPropertyName)]"            
            "[Reflection.AssemblyMetaData('SVG.AttributeName','$attrName')]"
            if ($paramIsDeprecated) {
                "[Reflection.AssemblyMetaData('SVG.Deprecated',`$true)]"
            }
            
            $elementData = $elementKV.Value.Data[$attrName]
            
            if ($elementData) {
                foreach ($dataKv in $elementData.GetEnumerator()) {
                    "[Reflection.AssemblyMetaData('SVG.$($dataKv.Key)', '$($dataKv.Value.ToString().Replace("'", "''"))')]"
                    if ($dataKv.Key -eq 'Value' -and $dataKv.Value) {
                        $dataKv.Value | ConvertSVGMetadataToParameterAttribute
                    }
                }
            }            
            "`$$paramName"
        )
    }
    
    $newPipeScriptSplat.parameter = $parameters
    $elementName = $elementKv.Key.Substring(0,1).ToUpper() + $elementKV.Key.Substring(1)
    $newPipeScriptSplat.functionName = "SVG.$($elementKV.Key)"    
    $newPipeScriptSplat.attribute = @(
        "[Reflection.AssemblyMetadata('SVG.ElementName', '$($elementKV.Key)')]"
        '[CmdletBinding(PositionalBinding=$false)]'
    )
    if ($elementName -eq 'SVG') {
        $newPipeScriptSplat.parameter += @{
            OutputPath = @(
@'
# The output path
[Parameter(ValueFromPipelineByPropertyName)]
[string]
$OutputPath                
'@
            )
        }
    }
    $newPipeScriptSplat.Process = {
        $paramCopy = [Ordered]@{} + $PSBoundParameters
        $myCmd = $MyInvocation.MyCommand

        $inputObject = $_
        $elementName = foreach ($myAttr in $myCmd.ScriptBlock.Attributes) {
            if ($myAttr.Key -eq 'SVG.ElementName') {
                $myAttr.Value
                break
            }
        }
        if (-not $elementName) { return }

        $writeSvgSplat = @{
            ElementName = $elementName
            Attribute   = $paramCopy                
        }

        if ($content) {
            $writeSvgSplat.Content = $content
        }
        if ($OutputPath) {
            $writeSvgSplat.OutputPath = $OutputPath
        }

        if ($data) {
            $writeSvgSplat.Data = $data
        }

        Write-SVG @writeSvgSplat
    }

    if (-not $parameters) { continue }
    $destination = Join-Path $PSScriptRoot "$($newPipeScriptSplat.functionName).ps1"
    $newScript = New-PipeScript @newPipeScriptSplat 
    if (-not $newScript) {
        $null = $null
    }
    $newScript| 
        Set-Content -Path $destination
    Get-Item -Path $destination
}

Write-Progress "Getting Element Data" "$elementName " -Id $id -Completed
