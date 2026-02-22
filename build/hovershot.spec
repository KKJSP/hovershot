# -*- mode: python ; coding: utf-8 -*-

block_cipher = None

a = Analysis(
    ['../src/hovershot/app.py'],
    pathex=[],
    binaries=[],
    datas=[('./icon/icon_32x32.png', '.')],
    hiddenimports=['PyQt6.QtCore', 'PyQt6.QtGui', 'PyQt6.QtWidgets'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='HoverShot',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False, # Set to False so the terminal doesn't pop up
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='HoverShot',
)
app = BUNDLE(
    coll,
    name='HoverShot.app',
    icon='./icon/icon.icns', # Add an .icns file path here if you have one!
    bundle_identifier='com.cradle.hovershot',
    info_plist={
        'LSUIElement': True, # This hides the app from the Dock (Status bar app style)
        'NSScreenCaptureUsageDescription': 'HoverShot needs to take screenshots to function.',
    },
)