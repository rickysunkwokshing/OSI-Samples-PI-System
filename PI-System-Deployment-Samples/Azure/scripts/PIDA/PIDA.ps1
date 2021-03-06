Configuration PIDA
{

    param(
    # Used to run installs. Account must have rights to conduct successful installs/configs
        [parameter(mandatory)]
        [PSCredential]$Credential,
    # PI Data Archive Install settings
		[string]$PIPath,
		[string]$PIProductID,
        [string]$archiveFilesSize = '256',
        [string]$PIHOME = 'F:\Program Files (x86)\PIPC',
        [string]$PIHOME64 = 'F:\Program Files\PIPC',
        [string]$PI_INSTALLDIR = 'F:\PI',
        [string]$PI_EVENTQUEUEDIR = 'F:\PI\queue',
        [string]$PI_ARCHIVEDATDIR = 'G:\PI\arc',
        [string]$PI_FUTUREARCHIVEDATDIR = 'G:\PI\arc\future',
        [string]$PI_ARCHIVESIZE = '256', #in MB

        # Parameters used for PIDA Collective
        [Parameter(Mandatory)]
        [string]$DeployHA,

        [Parameter(Mandatory)]
        [string]$OSIsoftTelemetry,

        [string]$PIDataArchivePrimary,
        [string]$PIDataArchiveSecondary,

        # Create Security groups used for FSTS Mappings
        [boolean]$EnableAdGroupCreation = $true,

        # AD Domain Security Group Names to map to OSIsoft FSTS PI Identities
        [String]$PIAdministratorsADGroup = 'PIAdmins',
        [String]$PIUsersADGroup = 'Domain Users',
        [String]$PIBuffersADGroup = 'PIBuffers',
        [String]$PIInterfacesADGroup = 'PIInterfaces',
        [String]$PIPointsAnalysisCreatorADGroup = 'PIPointsAnalysisCreator',
        [String]$PIWebAppsADGroup = 'PIWebApps',
        [String]$PIConnectorRelaysADGroup = 'PIConnectorRelays',
        [String]$PIDataCollectionManagersADGroup = 'PIDataCollectionManagers',
        [string]$DomainNetBiosName = 'ds',
        [string]$DomainAdminUserName = 'dummy1',
        [String]$DomainAdminPassword = 'dummy2',
        [String]$PrimaryDomainController = 'ds-dc-vm0'

        )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName xStorage
    Import-DscResource -ModuleName xNetworking
    Import-DscResource -ModuleName xPendingReboot
    Import-DscResource -ModuleName PSDSSupportPIDA
    Import-DscResource -ModuleName xActiveDirectory
    Import-DscResource -ModuleName PSDSSupportPIVS
	Import-DscResource -ModuleName cchoco


    [System.Management.Automation.PSCredential]$runAsCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList ("$DomainNetBiosName\$($Credential.UserName)", $Credential.Password)

    Node localhost {

        # Necessary if reboots are needed during DSC application/program installations
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        #region ### 1. VM PREPARATION ###
        # 1A. Check for new volumes. The uninitialized disk number may vary depending on EC2 type (i.e. temp disk or no temp disk). This logic will test to find the disk number of an uninitialized disk.
            # Elastic Block Storage for Binary Files
            xWaitforDisk Volume_F {
                DiskID           = 2
                retryIntervalSec = 30
                retryCount       = 20
            }
            xDisk Volume_F {
                DiskID      = 2
                DriveLetter = 'F'
                FSFormat    = 'NTFS'
                FSLabel     = 'Apps'
                DependsOn   = '[xWaitforDisk]Volume_F'
            }

            # Elastic Block Storage for Archive Files
            xWaitforDisk Volume_G {
                DiskID           = 3
                retryIntervalSec = 30
                retryCount       = 20
            }
            xDisk Volume_G {
                DiskID      = 3
                DriveLetter = 'G'
                FSFormat    = 'NTFS'
                FSLabel     = 'Archives'
                DependsOn   = '[xWaitforDisk]Volume_G'
            }

            # Elastic Block Storage for Queue Files
            xWaitforDisk Volume_H {
                DiskID           = 4
                retryIntervalSec = 30
                retryCount       = 20
            }
            xDisk Volume_H {
                DiskID      = 4
                DriveLetter = 'H'
                FSFormat    = 'NTFS'
                FSLabel     = 'Events'
                DependsOn   = '[xWaitforDisk]Volume_H'
            }

            # Elastic Block Storage for Backup Files
            xWaitforDisk Volume_I {
                DiskID           = 5
                retryIntervalSec = 30
                retryCount       = 20
            }
            xDisk Volume_I {
                DiskID      = 5
                DriveLetter = 'I'
                FSFormat    = 'NTFS'
                FSLabel     = 'Backups'
                DependsOn   = '[xWaitforDisk]Volume_I'
            }


        # 1B. Create Rule to open PI Net Manager Port
        xFirewall PINetManagerFirewallRule {
            Direction   = 'Inbound'
            Name        = 'PI-System-PI-Net-Manager-TCP-In'
            DisplayName = 'PI System PI Net Manager (TCP-In)'
            Description = 'Inbound rule for PI Data Archive to allow TCP traffic for access to the PI Server'
            Group       = 'PI Systems'
            Enabled     = 'True'
            Action      = 'Allow'
            Protocol    = 'TCP'
            LocalPort   = '5450'
            Ensure      = 'Present'
        }

        # 1C. Enable rules to allow Connection to Secondary when executing the CollectiveManager.ps1 script to form PI Data Archvie Collective.
        # The absence of this rule on the Secondary results in exception thrown during the use of get-WmiObject within CollectiveManager.ps1 script.
        # File Share SMB rule is for allowing archive and data file transer from Primary to Secondary.
        # For increased security, disable after Collective formation..
        xFirewall WindowsManagementInstrumentationDCOMIn {
            Name    = 'WMI-RPCSS-In-TCP'
            Enabled = 'True'
            Action  = 'Allow'
            Ensure  = 'Present'
        }

        xFirewall WindowsManagementInstrumentationWMIIn {
            Name    = 'WMI-WINMGMT-In-TCP'
            Enabled = 'True'
            Action  = 'Allow'
            Ensure  = 'Present'
        }

        xFirewall FileAndPrinterSharingSMBIn {
            Name    = 'FPS-SMB-In-TCP'
            Enabled = 'True'
            Action  = 'Allow'
            Ensure  = 'Present'
        }
        #endregion ### 1. VM PREPARATION ###


        #region ### 2. INSTALL AND SETUP ###

        # 2A. Installing Chocolatey to facilitate package installs.
		cChocoInstaller installChoco {
			InstallDir = 'C:\ProgramData\chocolatey'
		}

		# 2B. Install .NET Framework 4.8
		cChocoPackageInstaller 'dotnetfx' {
			Name = 'dotnetfx'
			DependsOn = "[cChocoInstaller]installChoco"
		}

        xPendingReboot RebootDotNet {
            Name      = 'RebootDotNet'
            DependsOn = '[cChocoPackageInstaller]dotnetfx'
        }

        #2C. Install PI Data Archive with Client Tools
        Package PISystem {
            Name                 = 'PI Server 2018 Installer'
            Path                 = $PIPath
            ProductId            = $PIProductID
            Arguments            = "/silent ADDLOCAL=PIDataArchive,PITotal,FD_AFExplorer,FD_AFDocs,PiPowerShell,pismt3 PIHOME=""$PIHOME"" PIHOME64=""$PIHOME64"" SENDTELEMETRY=""$OSIsoftTelemetry"" AFACKNOWLEDGEBACKUP=""1"" PI_INSTALLDIR=""$PI_INSTALLDIR"" PI_EVENTQUEUEDIR=""$PI_EVENTQUEUEDIR"" PI_ARCHIVEDATDIR=""$PI_ARCHIVEDATDIR"" PI_FUTUREARCHIVEDATDIR=""$PI_FUTUREARCHIVEDATDIR"" PI_ARCHIVESIZE=""$PI_ARCHIVESIZE"""
            Ensure               = 'Present'
            PsDscRunAsCredential = $runAsCredential # Admin creds due to limitations extracting install under SYSTEM account.
            ReturnCode           = 0, 3010, 1641
            DependsOn           = '[xDisk]Volume_F', '[xDisk]Volume_G', '[xDisk]Volume_H', '[xDisk]Volume_I', '[xPendingReboot]RebootDotNet'
        }

        # 2D. Initiate any outstanding reboots.
        xPendingReboot Reboot1 {
            Name      = 'PostInstall'
            DependsOn = '[Package]PISystem'
        }
        #endregion ### 2. INSTALL AND SETUP ###


        #region ### 3. IMPLEMENT OSISOFT FIELD SERVICE TECHNICAL STANDARDS ###

        #3. i - OPTIONAL - Create Corresponding AD Groups for the Basic Windows Integrated Security Roles. Relevant Service Accounts to map through these groups.
        # Aggregate Security Group parameters in to a single array.

        # Used for PI Data Archive Security setting of AD users and group.
        WindowsFeature ADPS {
            Name   = 'RSAT-AD-PowerShell'
            Ensure = 'Present'
        }


        $PISecurityGroups = @(
            @{Name = $PIBuffersADGroup; Description = 'Identity for PI Buffer Subsystem and PI Buffer Server'; },
            @{Name = $PIInterfacesADGroup; Description = 'Identity for PI Interfaces'; },
            @{Name = $PIUsersADGroup; Description = 'Identity for the Read-only users'; },
            @{Name = $PIPointsAnalysisCreatorADGroup; Description = 'Identity for PIACEService, PIAFService and users that can create and edit PI Points'; }
            @{Name = $PIWebAppsADGroup; Description = 'Identity for PI Vision, PI WebAPI, and PI WebAPI Crawler'; },
            @{Name = $PIConnectorRelaysADGroup; Description = 'Identity for PI Connector Relays'; },
            @{Name = $PIDataCollectionManagersADGroup; Description = 'Identity for PI Data Collection Managers'; }
        )
        # If $EnableAdGroupCreation set to $true, enumerate the PISecurityGroups array and create PI Security Groups in AD.
        if ($EnableAdGroupCreation) {
            ForEach ($Group in $PISecurityGroups) {
                xADGroup "CreatePIAdGroup_$($Group.Name)" {
                    GroupName        = $Group.Name
                    GroupScope       = 'Global'
                    Category         = 'Security'
                    Ensure           = 'Present'
                    Description      = $Group.Description
                    DomainController = $PrimaryDomainController
                    Credential       = $runAsCredential
                    DependsOn        = '[Package]PISystem', '[WindowsFeature]ADPS'
                }
            }

            ## OPTIONAL: To simplify remote access for Quickstart scenario, mapping 'Domain Admins' security group as PIAdmins. (NOT recommended for production.)
            xADGroup AddDomainAdminsToPIAdmins {
                GroupName        = $PIAdministratorsADGroup
                GroupScope       = 'Global'
                Category         = 'Security'
                Ensure           = 'Present'
                Description      = $Group.Description
                DomainController = $PrimaryDomainController
                Credential       = $runAsCredential
                MembersToInclude = 'Domain Admins'
                DependsOn        = '[Package]PISystem', '[WindowsFeature]ADPS'
            }
        }

        # 3A. Create identities for basic WIS roles
        $BasicWISRoles = @(
            @{Name = 'PI Buffers'; Description = 'Identity for PI Buffer Subsystem and PI Buffer Server'; },
            @{Name = 'PI Interfaces'; Description = 'Identity for PI Interfaces'; },
            @{Name = 'PI Users'; Description = 'Identity for the Read-only users'; },
            @{Name = 'PI Points&Analysis Creator'; Description = 'Identity for PIACEService, PIAFService and users that can create and edit PI Points'; }
            @{Name = 'PI Web Apps'; Description = 'Identity for PI Vision, PI WebAPI, and PI WebAPI Crawler'; },
            @{Name = 'PI Connector Relays'; Description = 'Identity for PI Connector Relays'; },
            @{Name = 'PI Data Collection Managers'; Description = 'Identity for PI Data Collection Managers'; }
        )
        Foreach ($BasicWISRole in $BasicWISRoles) {
            PIIdentity "SetBasicWISRole_$($BasicWISRole.Name)" {
                Name               = $BasicWISRole.Name
                Description        = $BasicWISRole.Description
                IsEnabled          = $true
                CanDelete          = $false
                AllowUseInMappings = $true
                AllowUseInTrusts   = $true
                Ensure             = "Present"
                PIDataArchive      = $env:COMPUTERNAME
                DependsOn          = '[Package]PISystem'
            }
        }

        # 3B. i - Remove default identities
        $DefaultPIIdentities = @(
            'PIOperators',
            'PISupervisors',
            'PIEngineers',
            'pidemo'
        )
        Foreach ($DefaultPIIdentity in $DefaultPIIdentities) {
            PIIdentity "DisableDefaultIdentity_$DefaultPIIdentity" {
                Name          = $DefaultPIIdentity
                Ensure        = "Absent"
                PIDataArchive = $env:COMPUTERNAME
                DependsOn     = '[Package]PISystem'
				PsDscRunAsCredential = $runAsCredential
            }
        }

        # 3B ii - Disable default identities
        $DefaultPIIdentities = @(
            'PIWorld',
            'piusers'
        )
        Foreach ($DefaultPIIdentity in $DefaultPIIdentities) {
            PIIdentity "DisableDefaultIdentity_$DefaultPIIdentity" {
                Name             = $DefaultPIIdentity
                IsEnabled        = $false
                AllowUseInTrusts = $false
                Ensure           = "Present"
                PIDataArchive    = $env:COMPUTERNAME
                DependsOn        = '[Package]PISystem', '[PIIdentity]DisableDefaultIdentity_pidemo' 
				PsDscRunAsCredential = $runAsCredential
            }
        }

        # 3C. Set PI Mappings
        $DesiredMappings = @(
            @{Name = 'BUILTIN\Administrators'; Identity = 'piadmins'}, ## OPTIONAL - Stronger security posture would exclude this mapping. Added here to simplify access for demo purposes.
            @{Name = $($DomainNetBiosName + '\' + $PIAdministratorsADGroup); Identity = 'piadmins'},
            @{Name = $($DomainNetBiosName + '\' + $PIBuffersADGroup); Identity = 'PI Buffers'},
            @{Name = $($DomainNetBiosName + '\' + $PIInterfacesADGroup); Identity = 'PI Interfaces'},
            @{Name = $($DomainNetBiosName + '\' + $PIPointsAnalysisCreatorADGroup); Identity = 'PI Points&Analysis Creator'},
            @{Name = $($DomainNetBiosName + '\' + $PIUsersADGroup); Identity = 'PI Users'},
            @{Name = $($DomainNetBiosName + '\' + $PIWebAppsADGroup); Identity = 'PI Web Apps'},
            @{Name = $($DomainNetBiosName + '\' + $PIConnectorRelaysADGroup); Identity = 'PI Connector Relays'},
            @{Name = $($DomainNetBiosName + '\' + $PIDataCollectionManagersADGroup); Identity = 'PI Data Collection Managers'}
        )
        Foreach ($DesiredMapping in $DesiredMappings) {
            if ($null -ne $DesiredMapping.Name -and '' -ne $DesiredMapping.Name) {
                PIMapping "SetMapping_$($DesiredMapping.Name)" {
                    Name          = $DesiredMapping.Name
                    PrincipalName = $DesiredMapping.Name
                    Identity      = $DesiredMapping.Identity
                    Enabled       = $true
                    Ensure        = "Present"
                    PIDataArchive = $env:COMPUTERNAME
                    DependsOn     = '[Package]PISystem', '[PIIdentity]DisableDefaultIdentity_piusers'
					PsDscRunAsCredential = $runAsCredential
                }
            }
        }

        # 3D. Set PI Database Security Rules
        $DatabaseSecurityRules = @(
            # PIAFLINK can only be updated if the PIAFLINK service has been configured and running.
            @{Name = 'PIARCADMIN'; Security = 'piadmins: A(r,w)'},
            @{Name = 'PIARCDATA'; Security = 'piadmins: A(r,w)'},
            @{Name = 'PIAUDIT'; Security = 'piadmins: A(r,w)'},
            @{Name = 'PIBACKUP'; Security = 'piadmins: A(r,w)'},
            # PIBACTHLEGACY applies to the old batch subsystem which predates the PI Batch Database.Unless the pibatch service is running, and there is a need to keep it running, this entry can be safely ignored.
            @{Name = 'PIDBSEC'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Data Collection Managers: A(r) | PI Users: A(r) | PI Web Apps: A(r)'},
            @{Name = 'PIDS'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Connector Relays: A(r,w) | PI Data Collection Managers: A(r) | PI Users: A(r) | PI Points&Analysis Creator: A(r,w)'},
            @{Name = 'PIHeadingSets'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'},
            @{Name = 'PIMAPPING'; Security = 'piadmins: A(r,w) | PI Web Apps: A(r)'},
            @{Name = 'PIModules'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'},
            @{Name = 'PIMSGSS'; Security = 'piadmins: A(r,w) | PIWorld: A(r,w) | PI Users: A(r,w)'},
            @{Name = 'PIPOINT'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Connector Relays: A(r,w) | PI Data Collection Managers: A(r) | PI Users: A(r) | PI Interfaces: A(r) | PI Buffers: A(r,w) | PI Points&Analysis Creator: A(r,w) | PI Web Apps: A(r)'},
            @{Name = 'PIReplication'; Security = 'piadmins: A(r,w) | PI Data Collection Managers: A(r)'},
            @{Name = 'PITRUST'; Security = 'piadmins: A(r,w)'},
            @{Name = 'PITUNING'; Security = 'piadmins: A(r,w)'},
            @{Name = 'PIUSER'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Connector Relays: A(r) | PI Data Collection Managers: A(r) | PI Users: A(r) | PI Web Apps: A(r)'}

            #@{Name = 'PIBatch'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'},
            #@{Name = 'PIAFLINK';            Security = 'piadmins: A(r,w)'},
            #@{Name = 'PIBATCHLEGACY';       Security='piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'},
            #@{Name = 'PICampaign'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'},
            #@{Name = 'PITransferRecords'; Security = 'piadmins: A(r,w) | PIWorld: A(r) | PI Users: A(r)'}
        )
        Foreach ($DatabaseSecurityRule in $DatabaseSecurityRules) {
            PIDatabaseSecurity "SetDatabaseSecurity_$($DatabaseSecurityRule.Name)" {
                Name          = $DatabaseSecurityRule.Name
                Security      = $DatabaseSecurityRule.Security
                Ensure        = "Present"
                PIDataArchive = $env:COMPUTERNAME
                DependsOn     = '[Package]PISystem'
            }
        }

        # 3F. Restrict use of the piadmin superuser. IMPORTANT NOTE - This change must occur last. Initial connection is via loop back trust. This gets disabled when this change occurs.
        PIIdentity Restrict_piadmin {
            Name                 = "piadmin"
            AllowUseInTrusts     = $true  ## NOTE - This is so local services can still operate. This is used by the loopback trust.
            AllowUseInMappings   = $false
            Ensure               = "Present"
            PIDataArchive        = $env:COMPUTERNAME
            PsDscRunAsCredential = $runAsCredential
            DependsOn            = '[Package]PISystem'
        }
        #endregion ### 3. IMPLEMENT OSISOFT FIELD SERVICE TECHNICAL STANDARDS ###


        #region ### 4. BACKUP CONFIGURATION ###
        # 4-A. Setup PI Server local backup scheduled task.
        Script PIBackupTask {
            GetScript            = {
                $task = (Get-ScheduledTask).TaskName | Where-Object {$_ -eq 'PI Server Backup'}
                Result = "$task"
            }

            TestScript           = {
                $task = (Get-ScheduledTask).TaskName | Where-Object {$_ -eq 'PI Server Backup'}
                if ($task) {
                    Write-Verbose -Message "'PI Server Backup' scheduled task already present. Skipping task install."
                    return $true
                }
                else {
                    Write-Verbose -Message "'PI Server Backup' scheduled task not found."
                    return $false
                }
            }

            SetScript            = {
                Write-Verbose -Message "Creating 'PI Server Backup' scheduled task. Check C:\PIBackupTaskErrors.txt and C:\PIBackupTaskOutput.txt for details."
                $result = Start-Process -NoNewWindow -FilePath "$env:PISERVER\adm\pibackuptask.bat" -WorkingDirectory "$env:PISERVER\adm"  -ArgumentList "I:\PIBackups -install" -Wait -PassThru -RedirectStandardError 'C:\PIBackupTaskErrors.txt' -RedirectStandardOutput 'C:\PIBackupTaskOutput.txt'
                $exitCode = $result.ExitCode.ToString()
                Write-Verbose -Message "Exit code: $exitCode"
            }

            PsDscRunAsCredential = $runAsCredential
            DependsOn            = '[Package]PISystem'
        }


        #endregion ### 4. BACKUP CONFIGURATION ###


        #region ### 5. CREATE PI DATA ARCHIVE COLLECTIVE ###
        if(($DeployHA -eq 'true') -and ($env:COMPUTERNAME -eq $PIDataArchivePrimary)) {
            xWaitForPIServer WaitingForSecondaryServer {
                Name = $PIDataArchiveSecondary
                PsDscRunAsCredential = $runAsCredential
            }
            xPIDACollective FormCollective {
                PICollectiveName = $PIDataArchivePrimary
                PIPrimaryName = $PIDataArchivePrimary
                PISecondaryNames = $PIDataArchiveSecondary
                BackupLocationOnPrimary = "I:\PIBackups"
                Credential = $runAsCredential

            }
        }

        

        #region 6. Deployment Test Firewall Rules
            xFirewall RSMForTestsEPMAP {
                Group   = 'Remote Service Management'
                Name    = 'Remote Service Management (RPC-EPMAP)'
                Ensure  = 'Present'
                Enabled = 'True'
            }

            xFirewall RSMForTestsRPC {
                Group   = 'Remote Service Management'
                Name    = 'Remote Service Management (RPC)'
                Ensure  = 'Present'
                Enabled = 'True'
            }
            xFirewall RSMForTestsNP {
                Group   = 'Remote Service Management'
                Name    = 'Remote Service Management (NP-In)'
                Ensure  = 'Present'
                Enabled = 'True'
            }

        xFirewall PingForTests {
            Name    = 'File and Printer Sharing (Echo Request - ICMPv4-In)'
            Ensure  = 'Present'
            Enabled = 'True'
        }   
        #endregion
    }
}

# SIG # Begin signature block
# MIIbzAYJKoZIhvcNAQcCoIIbvTCCG7kCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD/eADvnNHVWBSZ
# gUGJkHsSc2e3jmQMhLLaC3RsZfmI+aCCCo4wggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggVWMIIEPqADAgECAhAFTTVZN0yftPMcszD508Q/MA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTkwNjE3MDAwMDAw
# WhcNMjAwNzAxMTIwMDAwWjCBkjELMAkGA1UEBhMCVVMxCzAJBgNVBAgTAkNBMRQw
# EgYDVQQHEwtTYW4gTGVhbmRybzEVMBMGA1UEChMMT1NJc29mdCwgTExDMQwwCgYD
# VQQLEwNEZXYxFTATBgNVBAMTDE9TSXNvZnQsIExMQzEkMCIGCSqGSIb3DQEJARYV
# c21hbmFnZXJzQG9zaXNvZnQuY29tMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
# CgKCAQEAqbP+VTz8qtsq4SWhF7LsXqeDGyUwtDpf0vlSg+aQh2fOqJhW2uiPa1GO
# M5+xbr+RhTTWzJX2vEwqSIzN43ktTdgcVT9Bf5W2md+RCYE1D17jGlj5sCFTS4eX
# Htm+lFoQF0donavbA+7+ggd577FdgOnjuYxEpZe2lbUyWcKOHrLQr6Mk/bKjcYSY
# B/ipNK4hvXKTLEsN7k5kyzRkq77PaqbVAQRgnQiv/Lav5xWXuOn7M94TNX4+1Mk8
# 74nuny62KLcMRtjPCc2aWBpHmhD3wPcUVvTW+lGwEaT0DrCwcZDuG/Igkhqj/8Rf
# HYfnZQtWMnBFAHcuA4jJgmZ7xYMPoQIDAQABo4IBxTCCAcEwHwYDVR0jBBgwFoAU
# WsS5eyoKo6XqcQPAYPkt9mV1DlgwHQYDVR0OBBYEFNcTKM3o/Fjj9J3iOakcmKx6
# CPetMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzB3BgNVHR8E
# cDBuMDWgM6Axhi9odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVk
# LWNzLWcxLmNybDA1oDOgMYYvaHR0cDovL2NybDQuZGlnaWNlcnQuY29tL3NoYTIt
# YXNzdXJlZC1jcy1nMS5jcmwwTAYDVR0gBEUwQzA3BglghkgBhv1sAwEwKjAoBggr
# BgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAIBgZngQwBBAEw
# gYQGCCsGAQUFBwEBBHgwdjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNl
# cnQuY29tME4GCCsGAQUFBzAChkJodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRTSEEyQXNzdXJlZElEQ29kZVNpZ25pbmdDQS5jcnQwDAYDVR0TAQH/
# BAIwADANBgkqhkiG9w0BAQsFAAOCAQEAigLIcsGUWzXlZuVQY8s1UOxYgch5qO1Y
# YEDFF8abzJQ4RiB8rcdoRWjsfpWxtGOS0wkA2CfyuWhjO/XqgmYJ8AUHIKKCy6QE
# 31/I6izI6iDCg8X5lSR6nKsB2BCZCOnGJOEi3r+WDS18PMuW24kaBo1ezx6KQOx4
# N0qSrMJqJRXfPHpl3WpcLs3VA1Gew9ATOQ9IXbt8QCvyMICRJxq4heHXPLE3EpK8
# 2wlBKwX3P4phapmEUOWxB45QOcRJqgahe9qIALbLS+i5lxV+eX/87YuEiyDtGfH+
# dAbq5BqlYz1Fr8UrWeR3KIONPNtkm2IFHNMdpsgmKwC/Xh3nC3b27DGCEJQwghCQ
# AgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAX
# BgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNIQTIg
# QXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAVNNVk3TJ+08xyzMPnTxD8wDQYJ
# YIZIAWUDBAIBBQCggZ4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYB
# BAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHq5GrpZk9h0
# /jn9r98XRQzTxD/5eYP7XeJ996ZOHgYXMDIGCisGAQQBgjcCAQwxJDAioSCAHmh0
# dHA6Ly90ZWNoc3VwcG9ydC5vc2lzb2Z0LmNvbTANBgkqhkiG9w0BAQEFAASCAQAb
# 3kPpNZWyS1YxTHiKeuStP73uWgEqlkcxOPmc2VH2iVAPwYUVxYs33SwN1N9GVD1y
# mKCvxwdigLYI8sIHh7agsBWleCMlBg3YaoggjCPi1gZQbtPh1swJOcJonzaLXovT
# JJ8veMRWqcdrhtoN5KuDdc7fVjrCGqslrc+l+ZFIHFxnLk5HDj4mQivAplpA7ZZM
# /fGKdhpHU1Pq1jep72OtNwJgGuGUarM33xXXb/PzGQ7E82bbJBMehon2vC1gMWvq
# AgHR3h6fOlNL3uLBmrtd2ByYfLQtA2GU9xOMqUUuLxkv8CCJG52JE+C1V0A6I6cc
# UJzm6J8x8UEvKJ8juCkkoYIOPTCCDjkGCisGAQQBgjcDAwExgg4pMIIOJQYJKoZI
# hvcNAQcCoIIOFjCCDhICAQMxDTALBglghkgBZQMEAgEwggEPBgsqhkiG9w0BCRAB
# BKCB/wSB/DCB+QIBAQYLYIZIAYb4RQEHFwMwMTANBglghkgBZQMEAgEFAAQgHOuP
# lu5ed35y79haqPRfoIG8M/R87OGBYcgBAyQ3y1ACFQDH+qkafgFLNzum04Sj7g5H
# EvtnKxgPMjAxOTEwMDgxOTU2MTRaMAMCAR6ggYakgYMwgYAxCzAJBgNVBAYTAlVT
# MR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEfMB0GA1UECxMWU3ltYW50
# ZWMgVHJ1c3QgTmV0d29yazExMC8GA1UEAxMoU3ltYW50ZWMgU0hBMjU2IFRpbWVT
# dGFtcGluZyBTaWduZXIgLSBHM6CCCoswggU4MIIEIKADAgECAhB7BbHUSWhRRPfJ
# idKcGZ0SMA0GCSqGSIb3DQEBCwUAMIG9MQswCQYDVQQGEwJVUzEXMBUGA1UEChMO
# VmVyaVNpZ24sIEluYy4xHzAdBgNVBAsTFlZlcmlTaWduIFRydXN0IE5ldHdvcmsx
# OjA4BgNVBAsTMShjKSAyMDA4IFZlcmlTaWduLCBJbmMuIC0gRm9yIGF1dGhvcml6
# ZWQgdXNlIG9ubHkxODA2BgNVBAMTL1ZlcmlTaWduIFVuaXZlcnNhbCBSb290IENl
# cnRpZmljYXRpb24gQXV0aG9yaXR5MB4XDTE2MDExMjAwMDAwMFoXDTMxMDExMTIz
# NTk1OVowdzELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0
# aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBOZXR3b3JrMSgwJgYDVQQDEx9T
# eW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIENBMIIBIjANBgkqhkiG9w0BAQEF
# AAOCAQ8AMIIBCgKCAQEAu1mdWVVPnYxyXRqBoutV87ABrTxxrDKPBWuGmicAMpdq
# TclkFEspu8LZKbku7GOz4c8/C1aQ+GIbfuumB+Lef15tQDjUkQbnQXx5HMvLrRu/
# 2JWR8/DubPitljkuf8EnuHg5xYSl7e2vh47Ojcdt6tKYtTofHjmdw/SaqPSE4cTR
# fHHGBim0P+SDDSbDewg+TfkKtzNJ/8o71PWym0vhiJka9cDpMxTW38eA25Hu/ryS
# V3J39M2ozP4J9ZM3vpWIasXc9LFL1M7oCZFftYR5NYp4rBkyjyPBMkEbWQ6pPrHM
# +dYr77fY5NUdbRE6kvaTyZzjSO67Uw7UNpeGeMWhNwIDAQABo4IBdzCCAXMwDgYD
# VR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwZgYDVR0gBF8wXTBbBgtg
# hkgBhvhFAQcXAzBMMCMGCCsGAQUFBwIBFhdodHRwczovL2Quc3ltY2IuY29tL2Nw
# czAlBggrBgEFBQcCAjAZGhdodHRwczovL2Quc3ltY2IuY29tL3JwYTAuBggrBgEF
# BQcBAQQiMCAwHgYIKwYBBQUHMAGGEmh0dHA6Ly9zLnN5bWNkLmNvbTA2BgNVHR8E
# LzAtMCugKaAnhiVodHRwOi8vcy5zeW1jYi5jb20vdW5pdmVyc2FsLXJvb3QuY3Js
# MBMGA1UdJQQMMAoGCCsGAQUFBwMIMCgGA1UdEQQhMB+kHTAbMRkwFwYDVQQDExBU
# aW1lU3RhbXAtMjA0OC0zMB0GA1UdDgQWBBSvY9bKo06FcuCnvEHzKaI4f4B1YjAf
# BgNVHSMEGDAWgBS2d/ppSEefUxLVwuoHMnYH0ZcHGTANBgkqhkiG9w0BAQsFAAOC
# AQEAdeqwLdU0GVwyRf4O4dRPpnjBb9fq3dxP86HIgYj3p48V5kApreZd9KLZVmSE
# cTAq3R5hF2YgVgaYGY1dcfL4l7wJ/RyRR8ni6I0D+8yQL9YKbE4z7Na0k8hMkGNI
# OUAhxN3WbomYPLWYl+ipBrcJyY9TV0GQL+EeTU7cyhB4bEJu8LbF+GFcUvVO9muN
# 90p6vvPN/QPX2fYDqA/jU/cKdezGdS6qZoUEmbf4Blfhxg726K/a7JsYH6q54zoA
# v86KlMsB257HOLsPUqvR45QDYApNoP4nbRQy/D+XQOG/mYnb5DkUvdrk08PqK1qz
# lVhVBH3HmuwjA42FKtL/rqlhgTCCBUswggQzoAMCAQICEHvU5a+6zAc/oQEjBCJB
# TRIwDQYJKoZIhvcNAQELBQAwdzELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5bWFu
# dGVjIENvcnBvcmF0aW9uMR8wHQYDVQQLExZTeW1hbnRlYyBUcnVzdCBOZXR3b3Jr
# MSgwJgYDVQQDEx9TeW1hbnRlYyBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTE3
# MTIyMzAwMDAwMFoXDTI5MDMyMjIzNTk1OVowgYAxCzAJBgNVBAYTAlVTMR0wGwYD
# VQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEfMB0GA1UECxMWU3ltYW50ZWMgVHJ1
# c3QgTmV0d29yazExMC8GA1UEAxMoU3ltYW50ZWMgU0hBMjU2IFRpbWVTdGFtcGlu
# ZyBTaWduZXIgLSBHMzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAK8O
# iqr43L9pe1QXcUcJvY08gfh0FXdnkJz93k4Cnkt29uU2PmXVJCBtMPndHYPpPydK
# M05tForkjUCNIqq+pwsb0ge2PLUaJCj4G3JRPcgJiCYIOvn6QyN1R3AMs19bjwgd
# ckhXZU2vAjxA9/TdMjiTP+UspvNZI8uA3hNN+RDJqgoYbFVhV9HxAizEtavybCPS
# nw0PGWythWJp/U6FwYpSMatb2Ml0UuNXbCK/VX9vygarP0q3InZl7Ow28paVgSYs
# /buYqgE4068lQJsJU/ApV4VYXuqFSEEhh+XetNMmsntAU1h5jlIxBk2UA0XEzjwD
# 7LcA8joixbRv5e+wipsCAwEAAaOCAccwggHDMAwGA1UdEwEB/wQCMAAwZgYDVR0g
# BF8wXTBbBgtghkgBhvhFAQcXAzBMMCMGCCsGAQUFBwIBFhdodHRwczovL2Quc3lt
# Y2IuY29tL2NwczAlBggrBgEFBQcCAjAZGhdodHRwczovL2Quc3ltY2IuY29tL3Jw
# YTBABgNVHR8EOTA3MDWgM6Axhi9odHRwOi8vdHMtY3JsLndzLnN5bWFudGVjLmNv
# bS9zaGEyNTYtdHNzLWNhLmNybDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCB4AwdwYIKwYBBQUHAQEEazBpMCoGCCsGAQUFBzABhh5odHRwOi8v
# dHMtb2NzcC53cy5zeW1hbnRlYy5jb20wOwYIKwYBBQUHMAKGL2h0dHA6Ly90cy1h
# aWEud3Muc3ltYW50ZWMuY29tL3NoYTI1Ni10c3MtY2EuY2VyMCgGA1UdEQQhMB+k
# HTAbMRkwFwYDVQQDExBUaW1lU3RhbXAtMjA0OC02MB0GA1UdDgQWBBSlEwGpn4XM
# G24WHl87Map5NgB7HTAfBgNVHSMEGDAWgBSvY9bKo06FcuCnvEHzKaI4f4B1YjAN
# BgkqhkiG9w0BAQsFAAOCAQEARp6v8LiiX6KZSM+oJ0shzbK5pnJwYy/jVSl7OUZO
# 535lBliLvFeKkg0I2BC6NiT6Cnv7O9Niv0qUFeaC24pUbf8o/mfPcT/mMwnZolkQ
# 9B5K/mXM3tRr41IpdQBKK6XMy5voqU33tBdZkkHDtz+G5vbAf0Q8RlwXWuOkO9Vp
# JtUhfeGAZ35irLdOLhWa5Zwjr1sR6nGpQfkNeTipoQ3PtLHaPpp6xyLFdM3fRwmG
# xPyRJbIblumFCOjd6nRgbmClVnoNyERY3Ob5SBSe5b/eAL13sZgUchQk38cRLB8A
# P8NLFMZnHMweBqOQX1xUiz7jM1uCD8W3hgJOcZ/pZkU/djGCAlowggJWAgEBMIGL
# MHcxCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3JhdGlvbjEf
# MB0GA1UECxMWU3ltYW50ZWMgVHJ1c3QgTmV0d29yazEoMCYGA1UEAxMfU3ltYW50
# ZWMgU0hBMjU2IFRpbWVTdGFtcGluZyBDQQIQe9Tlr7rMBz+hASMEIkFNEjALBglg
# hkgBZQMEAgGggaQwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3
# DQEJBTEPFw0xOTEwMDgxOTU2MTRaMC8GCSqGSIb3DQEJBDEiBCBWapw43/Du5wkN
# QjKelB3ieq/GgrWDNIzgIL4JVMARGjA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCDE
# dM52AH0COU4NpeTefBTGgPniggE8/vZT7123H99h+DALBgkqhkiG9w0BAQEEggEA
# nHsNrV+Oju8g68xdaQImsxO8ZlekgQ3NnyYC3RaixNO+3bM24c6vsCsDJ+mvPkie
# j6z11rjKjhyATeaeOpS6XI8XBIoZTH6/xnedpbrtketj33DM++Oj8nUMPcRZBmFI
# Z172GsJkeRRRWb4gWCUK8E8sHxCJmhiMnKv7kpqk/oW7nzgXdN/5KRrgdzhV1lyv
# xa0NGnEc9wk2zrRn2kAbtcz0BePeZ0MOMwx6L/4dzl7ilPihDosxD1hRl7t88DTG
# lw6e16tTM7TiG5n5SoSzJpSQqqT193tBKF3Bw6sobf+PHgRULUhsaslFZLjqtmJf
# AmXoxxaQ6STE6cCsICuOpQ==
# SIG # End signature block
