#ifndef MyAppVersion
  #error MyAppVersion must be defined
#endif

#ifndef MyAppArchitecture
  #error MyAppArchitecture must be defined
#endif

#ifndef MyAppExecutable
  #error MyAppExecutable must be defined
#endif

#ifndef MyOutputDir
  #error MyOutputDir must be defined
#endif

#define MyAppName "PetRunner"
#define MyAppPublisher "hdminh"
#define MyAppExeName "PetRunner.exe"

#if MyAppArchitecture == "x64"
  #define MyArchitectureAllowed "x64compatible"
#else
  #error MyAppArchitecture must be x64
#endif

[Setup]
AppId={{E7AE5F8E-9BDE-4C5F-BD6B-783C8CD7FB42}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=PetRunner-{#MyAppVersion}-windows-{#MyAppArchitecture}-setup
SetupIconFile=..\..\Assets\AppIcon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed={#MyArchitectureAllowed}
ArchitecturesInstallIn64BitMode={#MyArchitectureAllowed}

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#MyAppExecutable}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
