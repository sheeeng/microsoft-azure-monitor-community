<#
File: main.ps1
Author: Azure Monitor Control Service
Email: amcsdev@microsoft.com
Description: This module contains code to help our customers migrate from MMA based configurations to AMA based configuration

Copyright (c) 2023 Microsoft
#>

# All the following variables are global
param(
    [Parameter(Mandatory=$True)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$True)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$True)]
    [string]$WorkspaceName,

    [Parameter(Mandatory=$True)]
    [string]$DcrName,

    [Parameter(Mandatory=$False)]
    [string]$OutputFolder = "./",

    [Parameter(Mandatory=$False)]
    [switch]$GetDcrPayload
)

#region Custom Type Definitions
# 1. Data Sources
class DCRPerfCounterDataSource
{
    [string]$name
    [string[]]$streams
    [int]$samplingFrequencyInSeconds
    [string[]]$counterSpecifiers
}

class DCRWindowsEventLogDataSource
{
    [string]$name
    [string[]]$streams
    [string[]]$xPathQueries
}

class DCRSyslogDataSource
{
    [string]$name
    [string[]]$streams
    [string[]]$facilityNames
    [string[]]$logLevels
}

#endregion

#region Utility functions

<#
.DESCRIPTION
    This function authenticates the user to Azure and ties the auth context to a specific Subscription
#>
function Set-AzSubscriptionContext {
    param (
        # This helps tie the AzContext to a specific Subscription 
        [Parameter(Mandatory=$true)][string] $SubscriptionId
    )

    Write-Host

    $azContext = Get-AzContext

    if ($null -ne $azContext)
    {
        Write-Host "Info: You are already logged into Azure" -ForegroundColor Green

        $currentAzContextSubId = $azContext.Subscription.Id

        if($currentAzContextSubId -ne $SubscriptionId)
        {
            Write-Host "Info: Switching to a different subscription context" -ForegroundColor Cyan
            
            try {
                Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Host "Error in setting the new Az Context: $PSItem" -ForegroundColor Red
                Write-Host
                Exit
            }

            Write-Host "Old subscription Id: $($currentAzContextSubId)"
            Write-Host "New Subscription Id: $($SubscriptionId)" -ForegroundColor Green
        }
    }
    else 
    {
        try 
        {
            Write-Host "Connecting to Azure..."
            Connect-AzAccount | Out-Null
            Set-AzContext -Subscription $SubscriptionId | Out-Null
            Write-Host "Successfully connected to Azure"
        }
        catch 
        {
            Write-Host "Error connection to Azure. Please try again!"
            Exit
        }
    }
}

<#
.DESCRIPTION
    This function generates the base arm template object that will be modified
#>
function Get-BaseArmTemplate
{
    $dcrResourceDef = [ordered]@{
        "type" = "Microsoft.Insights/dataCollectionRules"
        "apiVersion" = "2022-06-01" # Using the latest api version
        "name" = "[parameters('dcrName')]"
        "location" = "[parameters('dcrLocation')]"
        "properties" = [ordered]@{
            "description" = "A Data Collection Rule"
            "dataCollectionEndpointId" = $null
            "streamDeclarations" = @{}
            "dataSources" = [ordered]@{
                "performanceCounters" = @()
            }
            "destinations" = [ordered]@{
                "logAnalytics" = @(
                    [ordered]@{
                        "workspaceResourceId" = "[parameters('logAnalyticsWorkspaceArmId')]"
                        "name" = "myloganalyticsworkspace"
                    }
                )
            }
            "dataFlows" = @(
                [ordered]@{
                    "streams" = @()
                    "destinations" = @("myloganalyticsworkspace")
                }
            )
        }
    }

    $armTemplate = [ordered]@{
        "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        "contentVersion" = "1.0.0.0"
        "parameters" = [ordered]@{
            "dcrName" = [ordered]@{
                "type" = "string"
                "defaultValue" = $DcrName
                "metadata" = [ordered]@{
                    "description" = "The name of the Data Collection Rule as it will appear in the portal."
                }
            }
            "dcrLocation" = [ordered]@{
                "type" = "string"
                "defaultValue" = $Location #This should be the same as the one of the LAW referenced in `Destinations`
                "metadata" = [ordered]@{
                    "description" = "The location of the DCR. DCR is a regional resource."
                }
            }
            "logAnalyticsWorkspaceArmId" = [ordered]@{
                "type" = "string"
                "defaultValue" = "/subscriptions/$($SubscriptionId)/resourcegroups/$($ResourceGroupName)/providers/microsoft.operationalinsights/workspaces/$($WorkspaceName)"
                "metadata" = [ordered]@{
                    "description" = "The ARM Id of the log analytics workspace destination"
                }
            }
        }
        "resources" = @($dcrResourceDef)
    }

    $state["armTemplate"] = $armTemplate
}

function Get-UserLogAnalyticsWorkspace
{
    Write-Host
    Write-Host 'Info: Fetching the specified Log Analytics Workspace details' -ForegroundColor Cyan

    # The $Workspace Name in this context in case insensitive
    try {
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
        $workspace | Out-Null
    }
    catch {
        Write-Host "$PSItem" -ForegroundColor Red
        Write-Host
        Exit
    }
    
    Write-Host 'Info: Successfully retrieved the LAW details' -ForegroundColor Green
    $state["workspace"] = $workspace

    # Update the DCR Location
    $state.armTemplate.parameters.dcrLocation.defaultValue = $workspace.Location
}

<#
.DESCRIPTION
    Checks and parses the Windows Perf Counters on the workspace
#>
function Get-WindowsPerfCountersDataSource
{
    <#
    .DESCRIPTION
        This function applies Modifications if necessary to the counterSpecifier
    #>
    function Get-ValidatedWindowsCounterSpecifier
    {
        param(
            [Parameter(Mandatory=$true)][string] $counterSpecifier
        )
        # Case 0
        # \Memory(*)\Counter Name is an invalid perfCounter
        # Whenever we encounter it, transform it to \Memory\CounterName (with no instance specified)
        $counterSpecifier = $counterSpecifier.replace("Memory(*)", "Memory")
        return $counterSpecifier
    }

    $windowsPerfCounters = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind "WindowsPerformanceCounter"
    $state.armTemplate.dummy1
    if ($null -eq $windowsPerfCounters)
    {
        Write-Host "Info: Windows Performance Counters is not enabled on the workspace" -ForegroundColor Yellow
    }
    else {
        Write-Host "Info: Windows Performance Counters is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1

        $dcrPerfCounterStream = "Microsoft-Perf"
        $dcrWindowsPerfCountersTable = [ordered]@{}
        $count = 1
        foreach($dataSource in $windowsPerfCounters)
        {
            $properties = $dataSource.Properties
            $currentKey = [string]$properties.intervalSeconds

            if($dcrWindowsPerfCountersTable.Contains($currentKey))
            {
                $counterSpecifierValidated = Get-ValidatedWindowsCounterSpecifier -counterSpecifier "\$($properties.objectName)($($properties.instanceName))\$($properties.counterName)"
                $dcrWindowsPerfCountersTable[$currentKey].counterSpecifiers += $counterSpecifierValidated
            }
            else
            {
                $counterSpecifierValidated = Get-ValidatedWindowsCounterSpecifier -counterSpecifier "\$($properties.objectName)($($properties.instanceName))\$($properties.counterName)"
                $newPerfCounter = New-Object DCRPerfCounterDataSource
                $newPerfCounter.name = "DS_$("WindowsPerformanceCounter")_$($count)"
                $newPerfCounter.counterSpecifiers = $counterSpecifierValidated
                $newPerfCounter.samplingFrequencyInSeconds = $properties.intervalSeconds
                $newPerfCounter.streams = $dcrPerfCounterStream
                $dcrWindowsPerfCountersTable.Add($currentKey, $newPerfCounter)
                $count += 1
            }
        }

        foreach($key in $dcrWindowsPerfCountersTable.Keys)
        {
            $state.armTemplate.resources[0].properties["dataSources"]["performanceCounters"] += $dcrWindowsPerfCountersTable[$key]
        }

        $state.armTemplate.resources[0].properties["dataFlows"][0].streams += "Microsoft-Perf"
    }
}

<#
.DESCRIPTION
    Checks and parses the Linux Perf Counters on the workspace
#>
function Get-LinuxPerfCountersDataSource
{
    $linuxPerfCounters = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind "LinuxPerformanceObject"
    if ($null -eq $linuxPerfCounters)
    {
        Write-Host "Info: Linux Performance Counters is not enabled on the workspace" -ForegroundColor Yellow
    }
    else {
        Write-Host "Info: Linux Performance Counters is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1

        $dcrLinuxPerfCountersTable = [ordered]@{}
        $count = 1
        foreach($dataSource in $linuxPerfCounters)
        {
            $properties = $dataSource.Properties
            $currentKey = "$($properties.objectName)-$($properties.intervalSeconds)"
            $newPerfCounter = New-Object DCRPerfCounterDataSource
            $newPerfCounter.name = "DS_$("LinuxPerformanceCounter")_$($count)"
            $newPerfCounter.counterSpecifiers = @()
            $newPerfCounter.samplingFrequencyInSeconds = $properties.intervalSeconds
            $newPerfCounter.streams = @("Microsoft-Perf")
            
            foreach($counter in $properties.performanceCounters)
            {
                $newPerfCounter.counterSpecifiers += "\$($properties.objectName)($($properties.instanceName))\$($counter.counterName)"
            }

            $dcrLinuxPerfCountersTable.Add($currentKey, $newPerfCounter)
            $count += 1
        }

        foreach($key in $dcrLinuxPerfCountersTable.Keys)
        {
            $state.armTemplate.resources[0].properties.dataSources.performanceCounters += $dcrLinuxPerfCountersTable[$key]
        }

        $state.armTemplate.resources[0].properties["dataFlows"][0].streams += "Microsoft-Perf"
    }
}

<#
.DESCRIPTION
    Checks and parses Windows Event Logs
#>
function Get-WindowsEventLogs
{
    function Get-XPathQueryKey
    {
        param (
            [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.OperationalInsights.Models.PSWindowsEventDataSourceProperties] $WindowsEventProperties
        )

        # AMA defines five log levels 
        # Critical (1), Error (2), Warning(3), Information(4) Verbose(5) and Undefined/Anything else (0)
        # whereas MMA seems to only have three
        # Error (2), Warning(3) and Information(4) 
        # but if set to collect Error event at MMA, both Error and Critical will be collected as Errro event.

        $eventTypeStr = ""

        foreach($type in $WindowsEventProperties.eventTypes)
        {   
            if($eventTypeStr.Length -gt 0)
            {
                $eventTypeStr += " or "
            }

            if($type.eventType.ToString() -eq "Error")
            {
                $eventTypeStr += "Level=1 or Level=2"
            }
            elseif($type.eventType.ToString() -eq "Warning")
            {
                $eventTypeStr += "Level=3"
            }
            elseif($type.eventType.ToString() -eq "Information")
            {
                $eventTypeStr += "Level=4"
            }
        }

        #Example: [System[(Level=1 or Level=2 or Level=3)]]
        return "[System[($($eventTypeStr))]]"
    }
    
    $windowsEventLogs = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind "WindowsEvent"
    if ($null -eq $windowsEventLogs)
    {
        Write-Host "Info: Windows Event Logs is not enabled on the workspace" -ForegroundColor Yellow
    }
    else {
        Write-Host "Info: Windows Event Logs is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1

        $state.armTemplate.resources[0].properties.dataSources["windowsEventLogs"] = @()

        # Compressing all the workspace events into a single dcr event log
        $dcrWindowsEvent = New-Object DCRWindowsEventLogDataSource
        $dcrWindowsEvent.name = "DS_WindowsEventLogs"
        $dcrWindowsEvent.streams = @("Microsoft-Event")
        $dcrWindowsEvent.xPathQueries = @()

        $iter_count = 0
        foreach($windowsEvent in $windowsEventLogs)
        {
            $xPathQuery = Get-XPathQueryKey -WindowsEventProperties $windowsEvent.Properties
            $dcrWindowsEvent.xPathQueries += "$($windowsEvent.Properties.eventLogName)!*$($xpathQuery)"
            $iter_count += 1
        }

        if ($iter_count -ne 0)
        {
            $state.armTemplate.resources[0].properties.dataSources.windowsEventLogs += $dcrWindowsEvent
        }
        
        $state.armTemplate.resources[0].properties.dataFlows[0].streams += "Microsoft-Event"
    }
}

<#
.DESCRIPTION
    Checks and parses Linux SysLogs
#>
function Get-LinuxSysLogs
{

    #####################################################
    function Get-SyslogLevels
    {
        param (
            [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.OperationalInsights.Models.PSLinuxSyslogDataSourceProperties] $LinuxSyslogProperties
        )

        # Sorting the severities 
        # Sometimes the severities from the workpsace may not be in the correct order which is:
        # Emergency, Alert, Critical, Error, Warning, Notice, Info, Debug

        $sortedSeverities = New-Object string[] 8
        foreach($sev in $LinuxSyslogProperties.SyslogSeverities)
        {
            switch ($sev.Severity.value__) {
                0 { $sortedSeverities[0] = "Emergency"; Break }
                1 { $sortedSeverities[1] = "Alert"; Break }
                2 { $sortedSeverities[2] = "Critical"; Break }
                3 { $sortedSeverities[3] = "Error"; Break }
                4 { $sortedSeverities[4] = "Warning"; Break }
                5 { $sortedSeverities[5] = "Notice"; Break }
                6 { $sortedSeverities[6] = "Info"; Break }
                7 { $sortedSeverities[7] = "Debug" }
            }
        }

        # Remove the null entries
        $sortedSeverities = $sortedSeverities | Where-Object { $_ -ne $null }

        $syslogLevels = @()
        foreach($severity in $sortedSeverities)
        {
            switch($severity)
            {
                Emergency { $syslogLevels += "Emergency"; Break }
                Alert { $syslogLevels += "Alert"; Break }
                Critical { $syslogLevels += "Critical"; Break }
                Error { $syslogLevels += "Error"; Break }
                Warning { $syslogLevels += "Warning"; Break }
                Notice { $syslogLevels += "Notice"; Break }
                Info { $syslogLevels += "Info"; Break }
                Debug { $syslogLevels += "Debug" }
            }
        }

        [array]::Reverse($syslogLevels)
        return $syslogLevels
    }

    function Get-SyslogFacilityName
    {
        param (
            [Parameter(Mandatory=$true)][string] $MmaFacilityName
        )

        $amaFacilityName = ""
    
        switch($MmaFacilityName)
        {
            "auth"     { $amaFacilityName = "auth"; Break }
            "authpriv" { $amaFacilityName = "authpriv"; Break }
            "cron"     { $amaFacilityName = "cron"; Break }
            "daemon"   { $amaFacilityName = "daemon"; Break }
            "ftp"      { $amaFacilityName = "ftp"; Break }
            "kern"     { $amaFacilityName = "kern"; Break }
            "local0"   { $amaFacilityName = "local0"; Break }
            "local1"   { $amaFacilityName = "local1"; Break }
            "local2"   { $amaFacilityName = "local2"; Break }
            "local3"   { $amaFacilityName = "local3"; Break }
            "local4"   { $amaFacilityName = "local4"; Break }
            "local5"   { $amaFacilityName = "local5"; Break }
            "local6"   { $amaFacilityName = "local6"; Break }
            "local7"   { $amaFacilityName = "local7"; Break }
            "lpr"      { $amaFacilityName = "lpr"; Break  }
            "mail"     { $amaFacilityName = "mail"; Break }
            "news"     { $amaFacilityName = "news"; Break }
            "syslog"   { $amaFacilityName = "syslog"; Break }
            "user"     { $amaFacilityName = "user"; Break }
            "uucp"     { $amaFacilityName = "uucp"; Break }
            default    { $amaFacilityName = "*"; Break } # Is this safe to assume wildcad whenever there is no match?
        }

        return $amaFacilityName
    }
    #####################################################

    $linuxSyslogs = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind "LinuxSyslog"

    if($null -eq $linuxSysLogs)
    {
        Write-Host "Info: Linux SysLogs is not enabled on the workspace" -ForegroundColor Yellow
    }
    else {
        Write-Host "Info: Linux SysLogs is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1

        $state.armTemplate.resources[0].properties.dataSources["syslog"] = @()

        $dcrLinuxSyslogsTable = @{}
        $count = 1
        foreach($dataSource in $linuxSyslogs)
        {
            $properties = $dataSource.Properties
            if($properties.syslogSeverities.Length -gt 0)
            {
                $syslogLevels = Get-SyslogLevels -LinuxSyslogProperties $properties
                $logLevelsKey = $syslogLevels -join "-"
                if($dcrLinuxSyslogsTable.Contains($logLevelsKey))
                {
                    $dcrLinuxSyslogsTable[$logLevelsKey].facilityNames += Get-SyslogFacilityName  -mmaFacilityName $properties.syslogName
                }
                else
                {
                    $newLinuxSyslog = New-Object DCRSyslogDataSource
                    $newLinuxSyslog.name = "DS_$("LinuxSyslog")_$($count)"
                    $facilityName = Get-SyslogFacilityName -mmaFacilityName $properties.syslogName
                    $newLinuxSyslog.facilityNames = @($facilityName)
                    $newLinuxSyslog.logLevels = $syslogLevels
                    $newLinuxSyslog.streams = @("Microsoft-Syslog")
                    $dcrLinuxSyslogsTable.Add($logLevelsKey, $newLinuxSyslog)
                    $count += 1
                }
            }
        }

        foreach($key in $dcrLinuxSyslogsTable.Keys)
        {
            $state.armTemplate.resources[0].properties.dataSources.sysLog += $dcrLinuxSyslogsTable[$key]
        }

        $state.armTemplate.resources[0].properties.dataFlows[0].streams += "Microsoft-Syslog"
    }
} 

<#
.DESCRIPTION
    Fetches and parses any extension data sources present on the workspace
#>
function Get-ExtensionDataSources
{
    $workspaceExtensions = Get-AzOperationalInsightsIntelligencePack -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName

    # Case 1: VM Insights
    $vmInsights = $workspaceExtensions | Where-Object {$_.name -match ".*VMInsights*" }

    if ($null -ne $vmInsights -and $vmInsights.enabled -eq $True)
    {
        Write-Host 'Info: VM Insights Extension Data Source is enabled on the workspace' -ForegroundColor Green
        $state.dataSourcesCount += 1

        $state.armTemplate.resources[0].properties.dataSources["extensions"] = @()

        # VM Insights Perf counter
        $vmInsightsPerfCounter = [ordered]@{
            "name" = "VMInsightsPerfCounters"
            "streams" = @("Microsoft-InsightsMetrics")
            "samplingFrequencyInSeconds" = 60
            "counterSpecifiers" = @("\VmInsights\DetailedMetrics")
        }

        $state.armTemplate.resources[0].properties.dataSources.performanceCounters += $vmInsightsPerfCounter
        $state.armTemplate.resources[0].properties.dataFlows[0].streams += "Microsoft-InsightsMetrics"

        # VM Insights Extension
        $vmInsightsExtension = [ordered]@{
            "streams" = @("Microsoft-ServiceMap")
            "extensionName" = "DependencyAgent"
            "extensionSettings" = @{}
            "name" = "DependencyAgentDataSource"
        }

        Write-Host 'Info: Added Microsoft-InsightsMetrics and Microsoft-ServiceMap streams as part of the VM Insights Extension' -ForegroundColor Yellow

        $state.armTemplate.resources[0].properties.dataSources.extensions += $vmInsightsExtension
        $state.armTemplate.resources[0].properties.dataFlows[0].streams += "Microsoft-ServiceMap"
    }
    else {
        Write-Host 'Info: VM Insights Extension Data Source is not enabled on the workspace' -ForegroundColor Yellow
    }
}

<#
.DESCRIPTION
    Makes an ARM call to create a DCE
#>
function Get-ProvisionDCE
{
    Write-Host "Info: Provisioning a Data Collection Endpoint (DCE) on your behalf" -ForegroundColor Yellow
    $dceSubId = Read-Host ">>>>> Sub Id"
    $dceRg = Read-Host ">>>>> Resource Group"
    $dceName = Read-Host ">>>>> Name"
    Write-Host ">>>>> Location: $($state.armTemplate.parameters.dcrLocation.defaultValue)"
    $accessToken = Get-AzAccessToken
    $accessToken | Out-Null # Shouldn't print this out to the console

    $apiUrl = "https://management.azure.com/subscriptions/$($dceSubId)/resourceGroups/$($dceRg)/providers/Microsoft.Insights/dataCollectionEndpoints/$($dceName)?api-version=2022-06-01"
    $headers = @{
        'Authorization' = "Bearer $($accessToken.Token)"
    }

    $body = @{
        "location" = $state.armTemplate.parameters.dcrLocation.defaultValue
        "properties" = @{
            "description" = "A data Collection Endpoint"
        }
    }
    $bodyData = $body | ConvertTo-Json

    try {
        # Replace this AMCS PS CMDLET when it's ready
        $response = Invoke-RestMethod -Uri $apiUrl -Method PUT -Headers $headers -Body $bodyData -ContentType "application/json"
        $response | Out-Null 
    }
    catch {
        Write-Host "Error in provisioning the DCE: $PSItem" -ForegroundColor Red
        Write-Host
        Exit
    }

    $dceArmId = $response.id
    Write-Host "Info: The DCE was successfully provisioned: $($dceArmId)" -ForegroundColor Green

    return $dceArmId
}

<#
.DESCRIPTION
    Makes sure a Data Collection Endpoint Id is present in the payload whenever necessary
#>
function Set-FulfillDCERequirement
{
    if ($null -ne $state.armTemplate.resources[0].properties.dataCollectionEndpointId)
    {
        Write-Host "Info: DCE requirement already fulfilled" -ForegroundColor Green
    }
    else{
        Write-Host
        $provisionDCE = Read-Host "Do you want us to automatically provision a DCE for you? (y/n)"
        $provisionDCE = $provisionDCE.Trim().ToLower()

        $dceArmId = "/subscriptions/{subId}/resourceGroups/{resourceGroup}/providers/Microsoft.Insights/dataCollectionEndpoints/{dceName}"

        if ("y" -eq $provisionDCE)
        {
            $dceArmId = Get-ProvisionDCE
        }
        else{
            Write-Host "Action Required !!!: You will need to provide a valid Data Collection Endpoint Id in the parameters section of the DCR" -ForegroundColor DarkYellow
        }
        
        $state.armTemplate.parameters["dceArmId"] = [ordered]@{
            "type" = "string"
            "defaultValue" = $dceArmId
            "metadata" = [ordered]@{
                "description" = "The ARM Id of the Data Collection Endpoint being associated to this DCR"
            }
        }

        $state.armTemplate.resources[0].properties.dataCollectionEndpointId = "[parameters('dceArmId')]"
    }
}

function Set-MigrateMMABasedCustomTable
{
    param(
        [Parameter(Mandatory=$True)]
        [string]$tableName
    )

    $accessToken = Get-AzAccessToken
    $accessToken | Out-Null # Shouldn't print this out to the console

    $apiUrl = "https://management.azure.com/$($state.workspace.ResourceId)/tables/$($tableName)/migrate?api-version=2021-12-01-preview"
    $headers = @{
        'Authorization' = "Bearer $($accessToken.Token)"
    }

    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers
    $response | Out-Null

    Write-Host "Info: The table $($tableName) has been successfully migrated. Now, both MMA and AMA will be able to ingest custom logs into it." -ForegroundColor Green
}

<#
.DESCRIPTION
    Refer to this article https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-custom-text-log-migration
    This function migrates a MMA Custom text log table so it can be used as a destination for a new AMA custom text logs DCR.
    This is only for customers who want to preserve data
#>
function Set-MigrateMMACustomLogTableToAMACustomLogTable
{
    param(
        [Parameter(Mandatory=$True)]
        [string]$tableName
    )

    Write-Host
    $migrated = Read-Host "Has $($tableName) been migrated yet (y/n)?"
    $migrated = $migrated.Trim().ToLower()

    if ("y" -eq $migrated)
    {
        Write-Host "Info: No further action required. AMA will be able to ingest custom logs into this table: $($tableName)" -ForegroundColor Green
    }
    else {
        $migrate = Read-Host "Do you want us to migrate $($tableName) on your behalf (y/n)?"
        $migrate = $migrate.Trim().ToLower()

        if ("y" -eq $migrate)
        {
            Set-MigrateMMABasedCustomTable -tableName $tableName
            Write-Host "Info: No further action required. AMA will be able to ingest custom logs into this table: $($tableName)" -ForegroundColor Green
        }
        else {
            Write-Host "Info IMPORTANT !!!: Custom Logs Ingestion into $($tableName) requires steps from you" -ForegroundColor DarkYellow
        }
    }
}

<#
.DESCRIPTION
    Checks and parses Custom Logs
#>
function Get-CustomLogs
{
    <#
    .DESCRIPTION
        Extracts the file patterns for a given custom table
    #>
    function Get-FilePatterns
    {
        param(
            [Parameter(Mandatory=$true)][System.Object] $customLog
        )

        $filePatterns = @()

        foreach ($input in $customLog.Properties.Inputs)
        {
            if($null -ne $input.location.fileSystemLocations.linuxFileTypeLogPaths)
            {
                foreach ($linuxPath in $input.location.fileSystemLocations.linuxFileTypeLogPaths)
                {
                    $filePatterns += $linuxPath
                }
            }

            if($null -ne $input.location.fileSystemLocations.windowsFileTypeLogPaths)
            {
                foreach ($windowsPath in $input.location.fileSystemLocations.windowsFileTypeLogPaths)
                {
                    $windowsPathCorrected = $windowsPath.Replace("\\", "\")
                    $filePatterns += $windowsPathCorrected
                }    
            }
        }

        return $filePatterns 
    }

    # This returns MMA based custom tables or MMA based custom tables that have been migrated to Manual Schema Management
    # For MMA based custom tables that haven't been migrated yet, the customer needs to perform the migration for the custom logs ingestion via AMA to work
    # Another alternative will be to create a new custom table. Refer to this article https://learn.microsoft.com/en-us/azure/azure-monitor/agents/data-collection-text-log?tabs=portal
    $customLogs = Get-AzOperationalInsightsDataSource -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -Kind "CustomLog"
    #$state.armTemplate["customLogs"] = $customLogs

    if ($null -eq $customLogs)
    {
        Write-Host "Info: Custom Logs is not enabled on the workspace" -ForegroundColor Yellow
    }
    else {
        Write-Host "Info: Custom Logs is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1

        Write-Host "Info: IMPORTANT !!!: For each classic custom table below that hasn't been migrated, you will need to either migrate it or create a new AMA based custom table (in case you don't care about preserving data)" -ForegroundColor DarkYellow
        Write-Host "Info: Migrate a classic MMA based custom table >> https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-custom-text-log-migration" -ForegroundColor Cyan
        Write-Host "Info: Create a new AMA based custom table >> https://learn.microsoft.com/en-us/azure/azure-monitor/agents/data-collection-text-log?tabs=portal" -ForegroundColor Cyan
        
        $state.armTemplate.resources[0].properties.dataSources["logFiles"] = @()
        $iter_count = 1

        foreach($customLog in $customLogs)
        {
            # This name should be unique among all the stream declarations
            $customStreamName = "Custom-$($customLog.Properties.customLogName)"
            $streamDeclaration = [ordered]@{
                    "columns" = @(
                        @{
                            "name" = "TimeGenerated";
                            "type" = "datetime";
                        },
                        @{
                            "name" = "RawData";
                            "type" = "string";
                        }
                    )
                } 
            $state.armTemplate.resources[0].properties.streamDeclarations[$customStreamName] = $streamDeclaration
            #####################################################################
            $fPatterns = @(Get-FilePatterns -customLog $customLog)
            $customLogDataSource = [ordered]@{
                "name" = "customLogFile_DS_$($iter_count)"
                "streams" = @($customStreamName)
                "filePatterns" = $fPatterns
                "format" = "text"
                "settings" = [ordered]@{
                    "text" = [ordered]@{
                        "recordStartTimestampFormat" = "ISO 8601"
                    }
                }
            }

            $state.armTemplate.resources[0].properties.dataSources.logFiles += ($customLogDataSource)
            $state.armTemplate.resources[0].properties.dataFlows[0].streams += ($customStreamName)

            $iter_count += 1
            ######################################################################
            Set-MigrateMMACustomLogTableToAMACustomLogTable -tableName $customLog.Properties.customLogName
        }

        ########################################################
        Write-Host "Info IMPORTANT !!!: The script is unable to get the exact schema for each custom classic (migrated or not migrated) table" -ForegroundColor DarkYellow
        Write-Host "Info IMPORTANT !!!: You will need to update the `streamDeclarations` section of the DCR to make sure each stream declaration columns definition matches the corresponding output table in the workspace" -ForegroundColor DarkYellow

        ########################################################
        # DCE required for custom logs
        Write-Host "Info IMPORTANT !!!: A Data Collection Endpoint is required for the Ingestion of Custom Logs via DCR" -ForegroundColor DarkYellow

        Set-FulfillDCERequirement
    }
}

<#
.DESCRIPTION
    Cheks whether or not IIS Logs Collection is enabled on the workspace
#>
function Get-IsIISLogsDataSourceEnabled
{
    param(
        [Parameter(Mandatory=$true)][System.Object] $workspace
    )
    $accessToken = Get-AzAccessToken
    $accessToken | Out-Null # Shouldn't print this out to the console

    $apiUrl = "https://management.azure.com$($workspace.ResourceId)/dataSources?%24filter=kind%20eq%20'IISLogs'&api-version=2020-08-01"
    $headers = @{
        'Authorization' = "Bearer $($accessToken.Token)"
    }

    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers
    $response | Out-Null

    # response.value is an array
    # We return false when response.value is empty or response.value[0].properties.state = "OnPremiseDisabled"
    # We return True other
    if ($response.value.Count -ne 0 -and $response.value[0].properties.state -eq "OnPremiseEnabled")
    {
        Write-Host "Info: IIS Logs is enabled on the workspace" -ForegroundColor Green
        $state.dataSourcesCount += 1
        return $True
    }
    else {
        Write-Host "Info: IIS Logs is not enabled on the workspace" -ForegroundColor Yellow
        return $False
    }
}

function Get-UserLogAnalyticsWorkspaceDataSources
{
    # Query the workspaces data sources
    # All the data source types
    # 1. Windows Perf Counters: WindowsPerformanceCounter
    # 2. Linux Perf Counters: LinuxPerformanceObject
    # 3. Windows Event Logs: WindowsEvent
    # 4. Syslogs: LinuxSyslog
    # 5. Custom Logs: CustomLog
    # 6. IIS logs: IISLogs (This check is done via HTTP Rest)
    Write-Host
    Write-Host 'Info: Fetching the Log Analytics Workspace data sources' -ForegroundColor Cyan

    # Windows Performance Counters
    Get-WindowsPerfCountersDataSource

    # Linux Performance Counters
    Get-LinuxPerfCountersDataSource

    # Windows Event Logs
    Get-WindowsEventLogs

    # Linux Syslogs
    Get-LinuxSysLogs

    # Extensions Data Sources
    Get-ExtensionDataSources 

    # Custom Logs
    Get-CustomLogs

    # IIS Logs
    $isIISLogsEnabled = Get-IsIISLogsDataSourceEnabled -workspace $state.workspace
    if ($True -eq $isIISLogsEnabled)
    {
        # DCE required for iis logs
        Write-Host "Info IMPORTANT !!!: A Data Collection Endpoint is required for the Ingestion of IIS Logs via DCR" -ForegroundColor DarkYellow

        Set-FulfillDCERequirement

        $iisLogsDataSource = @([ordered]@{
                "name" = "myiislogsdatasource"
                "streams" = @("Microsoft-W3CIISLog")
                "logDirectorties" = @() #double check what to pass here. DCR contract has it.
        })
        $state.armTemplate.resources[0].properties["dataSources"]["iisLogs"] = $iisLogsDataSource
        $state.armTemplate.resources[0].properties["dataFlows"][0].streams += "Microsoft-W3CIISLog"
    }
}

<#
.DESCRIPTION
    This function demux the data flow
    If there are 4 distincts streams in dataFlows[0].streams, we end up with 4 dataFlow objects in dataFlows
#>
function Set-DemuxDataFlows
{
    $dataFlow = $state.armTemplate.resources[0].properties.dataFlows[0]

    $state.armTemplate.resources[0].properties.dataFlows = @()

    Write-Host "Info: Building data flows" -ForegroundColor Cyan

    foreach ($stream in $dataFlow.streams | Select-Object -Unique)
    {
        $newDataFlow = [ordered]@{
            "streams" = @($stream)
            "destinations" = @($dataFlow.destinations)
        }

        $state.armTemplate.resources[0].properties.dataFlows += $newDataFlow
    }
}

function Get-Output
{
    Write-Host
    if ($state.dataSourcesCount -eq 0)
    {
        Write-Host 'Info: No supported data sources were found on the workspace.' -ForegroundColor DarkYellow
        Write-Host 'Info: No output file(s) will be generated.' -ForegroundColor DarkYellow
        Write-Host
        Exit
    }
    else{
        # Build data flows
        Set-DemuxDataFlows

        # Do some clean up
        if ($state.armTemplate.resources[0].properties.dataSources.performanceCounters.Count -eq 0)
        {
            $state.armTemplate.resources[0].properties.dataSources.Remove("performanceCounters")
        }

        if ($null -eq $state.armTemplate.resources[0].properties.dataCollectionEndpointId)
        {
            $state.armTemplate.resources[0].properties.Remove("dataCollectionEndpointId")
        }

        if ($state.armTemplate.resources[0].properties.streamDeclarations.Count -eq 0)
        {
            $state.armTemplate.resources[0].properties.Remove("streamDeclarations")
        }

        # Generating the outputs
        Write-Host 'Info: Generating the main arm template file' -ForegroundColor Cyan
        $dcrArmTemplateFilePath = $OutputFolder + "main_dcr_arm_template.json"
        $state.armTemplate | ConvertTo-Json -Depth 100 | Out-File -FilePath $dcrArmTemplateFilePath

        Write-Host "Info: Done. Check your output folder ($($OutputFolder)) for all the generated files!" -ForegroundColor Green
        Write-Host
    }
}

#endregion

#region Logic
#$ErrorActionPreference = "SilentlyContinue"
$WarningPreference = 'SilentlyContinue'
Set-AzSubscriptionContext -SubscriptionId $SubscriptionId

###########################################################
$global:state = [ordered]@{
    "dataSourcesCount" = 0
}

Get-BaseArmTemplate
Get-UserLogAnalyticsWorkspace 
Get-UserLogAnalyticsWorkspaceDataSources
Get-Output

#endregion