Param (
    [Parameter(Mandatory=$True)]
    [string]$Publickey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# https://stackoverflow.com/questions/62343042/how-to-initialize-new-user-account-from-command-line
# https://gist.github.com/pjh/9753cd14400f4e3d4567f4553ba75f1d
# https://social.msdn.microsoft.com/Forums/vstudio/en-US/5ab1f9c4-1724-462b-bdda-a4ec6d429928/dllimport-using-userenv-createprofile?forum=csharpgeneral
function New-LocalUserProfile {

    [CmdletBinding()]
    [OutputType([string])]
    Param (
        [Parameter(Mandatory=$True, ValueFromPipelineByPropertyName=$True, Position=0)]
        [string]$UserName
    )

    $exists = $False
    try {
        Add-type -AssemblyName System.Web
        $secpass = ConvertTo-SecureString ([System.Web.Security.Membership]::GeneratePassword(16, 0)) -AsPlainText -Force

        New-LocalUser -Name $UserName -Password $secpass | Out-Null
        Add-LocalGroupMember -Group "Users" -Member $UserName | Out-Null
    } catch [Microsoft.PowerShell.Commands.UserExistsException] {
        $exists = $True
        #pass
    }

    if (-not ([System.Management.Automation.PSTypeName]'UserEnvCreateProfile').Type) {
        # https://docs.microsoft.com/en-us/windows/win32/api/userenv/nf-userenv-createprofile
        $body = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class UserEnvCreateProfile {
    [DllImport("userenv.dll", CharSet = CharSet.Auto)]
    public static extern int CreateProfile(
        [In] string pszUserSid,
        [In] string pszUserName,
        StringBuilder pszProfilePath,
        int cchProfilePath);
}
"@
        Add-Type $body | Out-Null
    }

    $user = [System.Security.Principal.NTAccount]::New($UserName)
    $userSID = $user.Translate([System.Security.Principal.SecurityIdentifier])

    if ($exists) {
        $prof = Get-WmiObject -Class Win32_UserProfile -Filter "sid = '$userSID'"
        $prof.LocalPath
    } else {
        $profpath = [System.Text.StringBuilder]::New(200)
        $ret = [UserEnvCreateProfile]::CreateProfile($userSID, $UserName, $profpath, $profpath.Capacity)
        if ($ret -ne 0) {
            throw "Failed to create Local user profile: $ret"
        }
        [string]$profpath
    }
}

function Install-MSVC {
    Write-Host 'Installing msvc.'
    # https://github.com/rust-lang/docker-rust/blob/ba375b78b82507ebae9242b294f3183a7cb8c22d/1.50.0/windowsservercore-1809/msvc/Dockerfile

    # Install MSVC
    $url = 'https://download.visualstudio.microsoft.com/download/pr/3105fcfe-e771-41d6-9a1c-fc971e7d03a7/8eb13958dc429a6e6f7e0d6704d43a55f18d02a253608351b6bf6723ffdaf24e/vs_Community.exe'
    $sha256 = '8eb13958dc429a6e6f7e0d6704d43a55f18d02a253608351b6bf6723ffdaf24e'
    Invoke-WebRequest -Uri $url -OutFile vs_Community.exe
    $actual256 = (Get-FileHash vs_Community.exe -Algorithm sha256).Hash
    if ($actual256 -ne $sha256) {
        Write-Host 'FAILED!'
        Write-Host ('expected: {0}' -f $sha256)
        Write-Host ('got:      {0}' -f $actual256)
        throw "checksum mismatch."
    }

    $proc = Start-Process -FilePath vs_Community.exe -Wait -PassThru -ArgumentList ' `
        --quiet --wait --norestart --nocache `
        --installPath C:\msvc `
        --add Microsoft.Component.MSBuild `
        --add Microsoft.VisualStudio.Component.Windows10SDK.17763 `
        --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
    if ($proc.ExitCode -ne 0) {
        throw "Failed to install msvc."
    }
    [Environment]::SetEnvironmentVariable('__VSCMD_ARG_NO_LOGO', '1', [EnvironmentVariableTarget]::Machine)
    Write-Host 'DONE Install msvc.'
}

function Install-Rustup {
    Write-Host 'Installing rustup.'

    # Install rust
    $env:RUSTUP_HOME = 'C:\rustup'
    $env:CARGO_HOME = 'C:\cargo'
    $env:RUST_VERSION = '1.51.0'

    if (-not (Test-Path -Path ${env:CARGO_HOME}\bin\rustup.exe -PathType Leaf)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $url = 'https://static.rust-lang.org/rustup/archive/1.24.1/x86_64-pc-windows-msvc/rustup-init.exe'
        $sha256 = '7e0f93cfe5d007092a7b772d027e5e16d43d610e10c82b6fbf6b02dbdc036c93'
        Invoke-WebRequest -Uri $url -OutFile rustup-init.exe
        $actual256 = (Get-FileHash rustup-init.exe -Algorithm sha256).Hash
        if ($actual256 -ne $sha256) {
            Write-Host 'FAILED!'
            Write-Host ('expected: {0}' -f $sha256)
            Write-Host ('got:      {0}' -f $actual256)
            throw "checksum mismatch."
        }

        New-Item ${env:CARGO_HOME}\bin -type directory -Force | Out-Null
        if (-not ${env:Path}.Contains('{0}\bin')) {
            $newPath = ('{0}\bin;{1}' -f ${env:CARGO_HOME}, ${env:PATH})
            [Environment]::SetEnvironmentVariable('PATH', $newPath, [EnvironmentVariableTarget]::Machine)
            [Environment]::SetEnvironmentVariable('PATH', $newPath, [EnvironmentVariableTarget]::Process)
        }

        $ErrorActionPreference = "Continue"
        # write log to stderr
        & .\rustup-init.exe -y -v --no-modify-path --default-toolchain ${env:RUST_VERSION} --default-host x86_64-pc-windows-msvc *>&1 | Write-Output
        $ErrorActionPreference = "Stop"

        [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $env:RUSTUP_HOME, [EnvironmentVariableTarget]::Machine)
        [Environment]::SetEnvironmentVariable('CARGO_HOME', $env:CARGO_HOME, [EnvironmentVariableTarget]::Machine)
    } else {
        Write-Host 'Skip install rustup.'
    }

    Write-Host 'DONE Install rustup.'
}

function Install-OpenSSH {
    Write-Host 'Installing OpenSSH.'

    # Install OpenSSH server
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Start-Service sshd
    Set-Service -Name sshd -StartupType 'Automatic'

    Write-Host 'DONE Install OpenSSH.'
}

function Setup-User {
    Write-Host 'Setup User.'

    # Add User
    $devhome = New-LocalUserProfile -UserName "dev"

    New-Item -Path "$devhome" -Name ".ssh" -ItemType "directory" -Force | Out-Null
    New-Item -Path "$devhome\.ssh" -Name "authorized_keys" -ItemType "file" -Value $Publickey -Force | Out-Null

    Write-Host 'DONE Setup User.'
}

function Install-ChocoAndGitBash {
    Write-Host 'Installing ChocoAndGitBash.'

    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    if (-not ${env:Path}.Contains('c:\ProgramData\chocolatey\bin')) {
        $newPath = ('c:\ProgramData\chocolatey\bin;{0}' -f ${env:PATH})
        [Environment]::SetEnvironmentVariable('PATH', $newPath, [EnvironmentVariableTarget]::Machine)
        [Environment]::SetEnvironmentVariable('PATH', $newPath, [EnvironmentVariableTarget]::Process)
    }

    & choco install git -params '"/GitAndUnixToolsOnPath"' -y *>&1 | Write-Output

    Write-Host 'DONE Install ChocoAndGitBash.'
}

function Main {
    Install-MSVC
    Install-OpenSSH
    Setup-User
    Install-Rustup
    Install-ChocoAndGitBash

    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Program Files\Git\bin\bash.exe" -PropertyType String -Force | Out-Null
    # For update env vars.
    Restart-Service sshd | Out-Null
}

Start-Transcript -Path C:\Log.txt | Out-Null
Main
Stop-Transcript | Out-Null
