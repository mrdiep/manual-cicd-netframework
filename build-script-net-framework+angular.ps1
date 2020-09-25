#danh sách branch muốn merge build
$MergeWithBranch = @("origin/SprintX")

#biến này để tự động đánh version của bản build, nếu tắt đi thì sẽ nhập bằng tay
#Thường nhập version bằng tay khi build để chuẩn bị lên prod, lúc này build sẽ nhập 3 số
$AutoIncreaseBuildVersion=$true

if (("-DisableAutoIncreaseBuildVersion".Equals($args[0]))) {
    $AutoIncreaseBuildVersion=$false
}

# sau khi build xong, sẽ deploy tới những thư mục này, có thể deoploy 1 list
$DeployToFolders = @("website-folder")
#build folder repository
$FolderWebsitePort80 = "website-folder"

$BinEnv="C:\folder chứa file powershell này"
$Source="C:\folder source code"
$DeployFolder="C:\folder deploy lên iis"

$TeamsChannel="webhook teams channel"

$MsBuildCli="C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
$ZipCli="C:\Program Files\7-Zip\7z.exe"

$script:packageVersion='0.0.0'
$script:zipPackageFile=''


# Hàm sẽ gửi 1 thông báo đến Ms-Teams channel
function Notification-Teams {
    [CmdletBinding()] param ($message)

    $payload = @{ "text" = "<pre>" +  $message + "</pre>" }
    $json = ConvertTo-Json $payload
    write-host $message
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $TeamsChannel
}

# Hàm sẽ gửi 1 thông báo đến khi deploy thành công
function Notification-EmailContent-Teams {
    $payload = @{
        "text" = '<pre style="background-color:white">(PEEK GIT LOG) <a href="https://xxxx-url/assets/commit-log.txt">https://xxxx-url/assets/commit-log.txt</a> <br/>'  + (Get-Content "$($BinEnv)\$($FolderWebsitePort80)\assets\commit-log.txt" | select -first 70 | out-string) + '</pre>'
    }
    $json = ConvertTo-Json $payload
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $TeamsChannel
    
    $payload = @{
        "text" = '<pre style="background-color:white">(PEEK PACKAGE INFO LOG) <a href="https://xxxx-url/assets/package.txt">https://xxxx-url/assets/package.txt</a> <br/>'  + (Get-Content "$($BinEnv)\$($FolderWebsitePort80)\assets\package.txt" | select -first 30 | out-string) + '</pre>'
    }
    $json = ConvertTo-Json $payload
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $TeamsChannel

    #gửi mail với nội dung tĩnh
    $mailBody = (Get-Content "$($BinEnv)\mail-body-template.html" | Out-String).Replace("aaaaaa", $packageVersion).Replace("bbbbbb", "XXXX.XXXX.XXXX.XXX")
    $payload = @{ "text" = $mailBody }
    $json = ConvertTo-Json $payload
    #write-host $message
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $TeamsChannel
}


# hàm này sẽ reset source code về nhánh muốn build. 
# theo prject hiện tại thì code base từ nhánh XXX, sau đó merge với sprint hiện tại
function Reset-Source {
    Set-Location -Path $Source
    git clean -f
    git fetch
    git reset --hard origin/XXX

    for($i=0; $i -lt $MergeWithBranch.Count; $i++) {
        write-host "git merge $($MergeWithBranch[$i])"
        git merge $MergeWithBranch[$i]
    }

    # write-host (git status)
}

# hàm này sẽ kiểm tra nhánh hiện tại có bị conflict code hay không. Nếu có thì bắn 1 thông báo qua MS-Teams channel
# chiến thuật: kiểm tra bằng câu lệnh git diff
function Proceed-If-Conflict {
    Set-Location -Path $Source

    $gitDiff=(git diff --name-only --diff-filter=U | Out-String)
    if ($gitDiff.Trim().Length.Equals(0)) { return $false }

    Notification-Teams "Conflicted files<br/>$($gitDiff)"
    return  $true
}


# hàm này chỉ dùng để kiểm tra cho build tự động,
# chiến thuật: mỗi lần build, đánh dấu cờ git sha1 commit vào 1 files. Mỗi lần build kiểm tra commit id đó với commit id hiện tại, nếu khác thì build. mã id giống thì k build lại
function Proceed-If-TriggerBuild {
    if (!$AutoIncreaseBuildVersion) { return $true }

    Set-Location -Path $Source
    [string] $buildVersionTempFile = "$($DeployFolder)\LastBuild.txt"
    [string] $gitLastVersion=(git rev-parse origin/Sprint4 | Out-String).Trim()
    
    if(![System.IO.File]::Exists($buildVersionTempFile)) { 
        Set-Content -Path $buildVersionTempFile -Value $gitLastVersion
        return $true
    }

    [string] $gitLastBuildVersion = Get-Content $buildVersionTempFile    
    if (!$gitLastBuildVersion.Equals($gitLastVersion)) {
        Set-Content -Path $buildVersionTempFile -Value $gitLastVersion
        return $true
    }

    $msg = "Commit: $($gitLastVersion) already build. Skip this version."
    Notification-Teams $msg
    return $false
}

# tạo version và folder version
# chiến thuật: Tự động đánh version bằng cấu trúc: năm.tháng.ngày.build-số
# nếu cờ AutoIncreaseBuildVersion được bật thì develoepr sẽ tự nhập bằng tay số buidl.
# Folder build theo tên version sẽ được tạo ra để chứa các file distributed hoặc api
function Create-Empty-Version-Folders {
   Set-Location -Path $DeployFolder

   $currentDate = (Get-Date).ToString("yyyy.MM.dd")
   $currentDateRegex = (Get-Date).ToString("^(yyyy\\.MM\\.dd") + "\.[0-9]+)$"
   
   $maxVersionToday = Get-ChildItem -Path $DeployFolder |
    Where-Object {$_.Name  -match $currentDateRegex} |
    Select-Object @{label="MinorVersion";expression={[int]::Parse($_.Name.Split('.')[3])}} |
    Select -ExpandProperty MinorVersion |
    measure -Maximum |
    select -ExpandProperty Maximum

   if (!$maxVersionToday) {
    $maxVersionToday  = 0
   }

   $maxVersionToday = $maxVersionToday + 1

   $rootFolder="$($currentDate).$($maxVersionToday)"
   
   #hảm chỉ cho phép nhập với format: yyyy.MM.dd
   if (!$AutoIncreaseBuildVersion) {    
        $rootFolder = Read-Host "Enter manual version (ex: 2020.08.01 yyyy.MM.dd)"

        while (!($rootFolder -match "^([0-9]{4}\.[0-9]{2}\.[0-9]{2})$")) {
            write-host "Wrong manual version format: ex: 2020.01.01  2020.12.31  2020.12.01"
            $rootFolder = Read-Host "Enter manual version (ex: 2020.08.01 yyyy.MM.dd)"
        }

        if ([System.IO.Directory]::Exists($rootFolder)) {
            Rename-Item $rootFolder "$rootFolder-BackupAt$((Get-Date).Ticks)"
        }
   }

   #tạo folder. out-null có nghĩa là không output ra ngoài màn hình
   New-Item -Path $rootFolder -ItemType Directory | Out-Null
   New-Item -Path "$($rootFolder)\config" -ItemType Directory | Out-Null

   #gán biến global ở phía trên, prefix đằng trước chỉ ra scope của biển
   $script:packageVersion = $rootFolder
}

# hàm này sẽ update assembly version cho đúng trước khi build
# nội dung: sẽ thay đổi file package.json và các file như AssemblyInfo
function Update-VersionConfig-Files {
    Set-Location -Path $Source
    $packagename=$packageVersion

    # load file json
    write-host "load and modity file package.json"
    $frontendConfigFile="$($Source)\App\XXXX\XXXX.WebApp\package.json"
    $packageCf = Get-Content -Path $frontendConfigFile -raw | ConvertFrom-Json
    $packageCf.version = $packagename
    $packageCf | ConvertTo-Json -depth 64 | set-content -Path $frontendConfigFile

    # sed là 3rd thư viện: nó sẽ replace text 1.0.0.0 thành chữ mới, rồi save file lại
    write-host "load and modity file AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.WebApi\Controllers\VersionController.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.Constant\Properties\AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.Data\Properties\AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.Domain\Properties\AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.Model\Properties\AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.WebApi\Properties\AssemblyInfo.cs"
    sed -i "s/1.0.0.0/$($packagename)/g" "$($Source)\App\XXXX\XXXX.WebApp\Properties\AssemblyInfo.cs"
}

#hàm này là hàm chính, dùng build front end và backend
function Build-Package {

    # chuyển folder làm việc về folder WebApp, nơi có file package.json. Mục đích: để chạy lệnh npm run prod phía dưới
    Set-Location -Path "$($Source)\App\XXXX\XXXX.WebApp"
    write-host "Start Build FrontEnd"
    npm run prod

    if (!$LASTEXITCODE.Equals(0)) {
        Write-Error "Error"
        Notification-Teams "Build fail $($packageVersion)"
        return [string]::Empty
    }

    #Move folder dist to the new folder in distributed folder
    $buildFolder="$($DeployFolder)\$($packageVersion)\build-$($packageVersion)"
    Move-Item -Path "$($Source)\App\XXXX\XXXX.WebApp\dist" -Destination $buildFolder  | Out-Null

    $publishXmlCfFile = "$($BinEnv)\FolderProfile1.pubxml"

    [xml]$buildXml = Get-Content $publishXmlCfFile
    $buildXml.Project.PropertyGroup.publishUrl = "$($buildFolder)\api"
    $buildXml.Save($publishXmlCfFile)

    # restore nuget
    write-host "Restoring nuget package..."
    #& "$($BinEnv)\nuget.exe" "restore" "$($Source)\App\XXXX\XXXX.WebApi\XXXX.WebApi.csproj"  | Out-Host
    
    write-host "Build API using msbuild..."
    & $MsBuildCli "$($Source)\App\XXXX\XXXX.WebApi\XXXX.WebApi.csproj" /p:DeployOnBuild=true /consoleloggerparameters:ErrorsOnly /p:PublishProfile="$($BinEnv)\FolderProfile1.pubxml" | Out-Host

    if (!([System.IO.Directory]::Exists("$($buildFolder)\assets\configurations"))) {
        Notification-Teams "Fail: no folder configurations $($packageVersion)"
        return [string]::Empty
    }

    if (!([System.IO.Directory]::Exists("$($buildFolder)\api"))) {
        Notification-Teams "Fail: no folder api $($packageVersion)"
        return [string]::Empty
    }

    if (!([System.IO.File]::Exists("$($buildFolder)\api\web.config"))) {
        Notification-Teams "Fail: no file  api\web.config $($packageVersion)"
        return [string]::Empty
    }


    Write-Host "Move all config files to folder config out side"

    # xóa các file config trong bản build
    Move-Item -Path "$($buildFolder)\assets\configurations" -Destination "$($DeployFolder)\$($packageVersion)\config"  | Out-Null
    Move-Item -Path "$($buildFolder)\web.config" -Destination "$($DeployFolder)\$($packageVersion)\config\web.config"  | Out-Null
    Move-Item -Path "$($buildFolder)\api\web.config" -Destination "$($DeployFolder)\$($packageVersion)\config\api-web.config"  | Out-Null

    Set-Location -Path "$($Source)"
    git log --graph | Set-content -Path "$($buildFolder)\assets\commit-log.txt"

    # tạo file commit-log.txt và package.txt
    Create-Logger-Files $buildFolder
    
    # đóng gói package lại thành file zip
    $zipPackageFile = "$($DeployFolder)\$($packageVersion)\build-$($packageVersion).zip"
    & $ZipCli a $zipPackageFile "$($buildFolder)\*" | Out-Host

    $script:zipPackageFile = $zipPackageFile
}

# hàm tạo các file log để trace lại thông tin nếu có sự cố
function Create-Logger-Files {
    [CmdletBinding()] param ($buildFolder)

    Set-Location -Path "$($Source)"
    (git status) + (git log --graph) | Set-content -Path "$($buildFolder)\assets\commit-log.txt"
    ("Version: $($packageVersion)") | set-content -Path "$($buildFolder)\assets\package.txt"
    ("Build at: $((Get-Date).ToString('HH:mm dd/MMM/yyyy'))") | add-content -Path "$($buildFolder)\assets\package.txt"
    "Node version: $(node -v)" | add-content -Path "$($buildFolder)\assets\package.txt"

    #list tên tất cả file, folder, lưu vào file assets/package.txt
    (cmd /c dir $buildFolder /b /s | out-string).Replace($buildFolder, ".") | add-content -Path "$($buildFolder)\assets\package.txt"
}

# Un zip file package tới folder bất kì, trong trường hợp này là unzip tới folder port-80 để tự động deploy
function Unzip-To {
    [CmdletBinding()] param ($destFolder)
    & $ZipCli x $zipPackageFile -aoa -o"$($DeployFolder)\$($destFolder)\" |Out-Host
}

#thường các bản build nhập tay là dành cho deploy lên prod hoặc staging(vì quy định build có 3 số). Nên, trong trường hợp nhập tay 3 số thì sẽ hàm này sẽ copy zip file ra thự mục assets
# mục đích: để server team có thể download package qua url: XXXX/assets/build-xxxx.xx.xx.zip về
function Copy-Package-To-Asset-Folder {
     if ($AutoIncreaseBuildVersion) { return $false }
     Move-Item -Path $zipPackageFile -Destination "$($DeployFolder)\$($FolderWebsitePort80)\assets" | out-host

     if ($AutoIncreaseBuildVersion) { return $true }
}

#dưới đây là các code, code sẽ chạy tuần tự
Reset-Source
if (Proceed-If-Conflict) { exit 1 }

#hàm này chỉ được dùng kết hợp cùng với job tự động (setup 10min 1 lần) để chạy AutoBuild.
#if (!(Proceed-If-TriggerBuild))  { exit 1 } #For auto build only

Create-Empty-Version-Folders
Build-Package

# deploy to 
for($i=0; $i -lt $DeployToFolders.Count; $i++) {
    Unzip-To $DeployToFolders[$i]
}

Notification-EmailContent-Teams
Copy-Package-To-Asset-Folder