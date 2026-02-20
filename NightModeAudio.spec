# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['night_mode_audio.py'],
    pathex=[],
    binaries=[],
    datas=[('menu_icon.png', '.'), ('menu_icon_on.png', '.')],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='NightModeAudio',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['app_icon.png'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='NightModeAudio',
)
app = BUNDLE(
    coll,
    name='NightModeAudio.app',
    icon='app_icon.png',
    bundle_identifier='com.lizstudio.nightmodeaudio',
    info_plist={
        'NSMicrophoneUsageDescription': 'This app needs access to the microphone to process system audio via BlackHole.',
        'LSUIElement': True, # 메뉴바 전용 앱 (Dock 아이콘 숨김)
        'CFBundleDisplayName': 'Night Mode',
        'CFBundleShortVersionString': '0.1.0',
        'NSHighResolutionCapable': 'True'
    },
)
