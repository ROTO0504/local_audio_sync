#!/usr/bin/env ruby
# frozen_string_literal: true

# Broadcast Upload Extension ターゲットを Runner.xcodeproj へプログラム的に追加する。
#
# 背景: ios/BroadcastExtension/ にソース(SampleHandler.swift)・Info.plist・
# entitlements は用意されているが、Xcode プロジェクトの「ターゲット」として
# 登録されていないため、アプリに Extension がビルド・同梱されず、
# RPSystemBroadcastPickerView の preferredExtension が実在せずボタンが機能しない。
#
# 手書きの pbxproj 編集は破損リスクが高いため、CocoaPods も利用する公式ツール
# xcodeproj gem で正しく追加する。冪等(既にターゲットがあれば何もしない)。
#
# 実行: ruby ios/scripts/add_broadcast_extension.rb
# 前提: gem 'xcodeproj'(macOS CI では CocoaPods 依存で通常利用可)

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'
EXT_NAME     = 'BroadcastExtension'
BUNDLE_ID    = 'com.roto0504.localAudioSync.BroadcastExtension'
TEAM_ID      = '7H7U867AYF'
DEPLOY       = '13.0'
SWIFT        = '5.0'

project = Xcodeproj::Project.open(PROJECT_PATH)

# --- 冪等性: 既に存在するなら何もしない -----------------------------------
if project.targets.any? { |t| t.name == EXT_NAME }
  puts "[add_broadcast_extension] '#{EXT_NAME}' ターゲットは既に存在します。スキップ。"
  exit 0
end

runner = project.targets.find { |t| t.name == 'Runner' }
raise "Runner ターゲットが見つかりません" if runner.nil?

# --- Extension ターゲットを作成(app_extension / iOS / Swift) ---------------
ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOY, nil, :swift)

# --- ナビゲータ用グループと SampleHandler.swift の参照 ----------------------
group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == EXT_NAME
end
group ||= project.main_group.new_group(EXT_NAME, EXT_NAME)

sample = group.files.find { |f| f.path == 'SampleHandler.swift' }
sample ||= group.new_file('SampleHandler.swift')
ext.add_file_references([sample])

# Info.plist / entitlements はコンパイル対象ではないが、ナビゲータへ参照を置く。
group.new_file('Info.plist') unless group.files.any? { |f| f.path == 'Info.plist' }
unless group.files.any? { |f| f.path == 'BroadcastExtension.entitlements' }
  group.new_file('BroadcastExtension.entitlements')
end

# --- ReplayKit をリンク -----------------------------------------------------
ext.add_system_framework('ReplayKit')

# --- ビルド設定 -------------------------------------------------------------
# new_target は Debug / Release を作る。Flutter は Profile も使うので後で追加。
def apply_ext_settings(config)
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER']   = BUNDLE_ID
  bs['PRODUCT_NAME']                = '$(TARGET_NAME)'
  bs['INFOPLIST_FILE']              = 'BroadcastExtension/Info.plist'
  bs['CODE_SIGN_ENTITLEMENTS']      = 'BroadcastExtension/BroadcastExtension.entitlements'
  bs['IPHONEOS_DEPLOYMENT_TARGET']  = DEPLOY
  bs['SWIFT_VERSION']               = SWIFT
  bs['DEVELOPMENT_TEAM']            = TEAM_ID
  bs['CODE_SIGN_STYLE']             = 'Automatic'
  bs['TARGETED_DEVICE_FAMILY']      = '1,2'
  bs['MARKETING_VERSION']           = '1.0'
  bs['CURRENT_PROJECT_VERSION']     = '1'
  bs['GENERATE_INFOPLIST_FILE']     = 'NO'
  bs['ENABLE_BITCODE']              = 'NO'
  bs['SKIP_INSTALL']                = 'YES' # Extension は Runner へ埋め込むため単体 install しない
  bs['CLANG_ENABLE_MODULES']        = 'YES'
  bs['LD_RUNPATH_SEARCH_PATHS']     = ['$(inherited)', '@executable_path/Frameworks',
                                       '@executable_path/../../Frameworks']
end

ext.build_configurations.each { |c| apply_ext_settings(c) }

# Debug は最適化オフ
ext.build_configurations.each do |c|
  if c.name == 'Debug'
    c.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    c.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
  else
    c.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
  end
end

# --- Profile 構成を追加(Release を複製)-----------------------------------
config_list = ext.build_configuration_list
unless config_list.build_configurations.any? { |c| c.name == 'Profile' }
  release = config_list.build_configurations.find { |c| c.name == 'Release' }
  profile = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  profile.name = 'Profile'
  profile.build_settings = release.build_settings.dup
  config_list.build_configurations << profile
end

# --- Runner が Extension に依存 + 埋め込み(Embed App Extensions)-----------
runner.add_dependency(ext)

# 重要: 「Embed App Extensions」コピーフェーズは Flutter の "Thin Binary"
# スクリプトフェーズより **前** に置く。末尾に置くと新ビルドシステムが
# "Cycle inside Runner; building could produce unreliable results" を出す
# (appex コピーと Thin Binary が相互依存になる)。これは Flutter + App
# Extension で既知の問題で、順序を前にすると解消する。
embed = runner.copy_files_build_phases.find do |p|
  p.symbol_dst_subfolder_spec == :plug_ins
end
unless embed
  embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
  embed.name = 'Embed App Extensions'
  embed.symbol_dst_subfolder_spec = :plug_ins
  thin_idx = runner.build_phases.index { |p| p.display_name == 'Thin Binary' }
  if thin_idx
    runner.build_phases.insert(thin_idx, embed)
  else
    runner.build_phases << embed
  end
end
build_file = embed.add_file_reference(ext.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy', 'CodeSignOnCopy'] }

project.save
puts "[add_broadcast_extension] '#{EXT_NAME}' ターゲットを追加し Runner へ埋め込みました。"
puts "  targets: #{project.targets.map(&:name).join(', ')}"
