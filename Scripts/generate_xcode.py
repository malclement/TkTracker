#!/usr/bin/env python3
"""Generate the dependency-free macOS app target used for App Intents extraction."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = root / 'dist/TkTracker.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def quote(value):
    return json.dumps(str(value))
objects = []
def obj(name, body):
    objects.append(f'{uid(name)} = {{ {body} }};')
    return uid(name)
source_ids, source_builds, resource_ids, resource_builds = [], [], [], []
for path in sorted((root / 'Sources/TkTracker').rglob('*.swift')):
    relative = path.relative_to(root)
    ref = obj(str(relative), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote("../" + str(relative))}; sourceTree = SOURCE_ROOT;')
    build = obj('build:' + str(relative), f'isa = PBXBuildFile; fileRef = {ref};')
    source_ids.append(ref); source_builds.append(build)
for relative, kind in [('Sources/TkTracker/Resources/pricing.json', 'text.json'), ('Sources/TkTracker/Resources/en.lproj', 'folder'), ('dist/AppIcon.icns', 'image.icns')]:
    ref = obj(relative, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote("../" + relative)}; sourceTree = SOURCE_ROOT;')
    build = obj('build:' + relative, f'isa = PBXBuildFile; fileRef = {ref};')
    resource_ids.append(ref); resource_builds.append(build)
def listing(values):
    return '(' + ','.join(values) + ',)'
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TkTracker.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; name = Products; children = ({product},); sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = {listing(source_ids + resource_ids + [products])}; sourceTree = "<group>";')
sources = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {listing(source_builds)}; runOnlyForDeploymentPostprocessing = 0;')
resources = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {listing(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
settings = {
    'PRODUCT_NAME': 'TkTracker', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.clementmalige.tktracker',
    'MACOSX_DEPLOYMENT_TARGET': '15.0', 'SDKROOT': 'macosx', 'SWIFT_VERSION': '5.0',
    'GENERATE_INFOPLIST_FILE': 'NO', 'INFOPLIST_FILE': '$(SRCROOT)/../Support/Info.plist',
    'CODE_SIGN_ENTITLEMENTS': '$(SRCROOT)/../Support/TkTracker.entitlements',
    'SWIFT_EMIT_LOC_STRINGS': 'YES', 'ENABLE_HARDENED_RUNTIME': 'YES',
    'SWIFT_COMPILATION_MODE': 'wholemodule', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
    'ARCHS': 'arm64 x86_64', 'ONLY_ACTIVE_ARCH': 'NO',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks',
}
config = obj('config', 'isa = XCBuildConfiguration; name = Release; buildSettings = {' + ''.join(f'{k} = {quote(v)};' for k,v in settings.items()) + '};')
configs = obj('configs', f'isa = XCConfigurationList; buildConfigurations = ({config},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; name = TkTracker; productName = TkTracker; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {configs}; buildPhases = ({sources},{frameworks},{resources},); buildRules = (); dependencies = ();')
project_id = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {project_id}; }}\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'TkTracker.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TkTracker.app" BlueprintName="TkTracker" ReferencedContainer="container:TkTracker.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Release"/><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Release"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print(project)
