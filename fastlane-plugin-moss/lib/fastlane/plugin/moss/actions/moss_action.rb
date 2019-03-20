require 'fastlane/action'
require 'json'
require_relative '../helper/moss_helper'

module Fastlane
  module Actions
    class MossAction < Action

      #####################################################
      # @!group constant name
      #####################################################
      HASH_LIST_NAME = 'HashList'.freeze
      CARTFILE_RESOLVED_NAME = 'Cartfile.resolved'.freeze


      #####################################################
      # @!group constant paths
      #####################################################
      WORK_PATH = '~/.moss'.freeze
      CACHE_PATH = (WORK_PATH + '/cache').freeze
      TMP_PATH = (WORK_PATH + '/tmp').freeze
      RECEIVE_TMP_PATH = (WORK_PATH + '/receive_tmp').freeze
      CARTFILE_RESOLVED_PATH = CARTFILE_RESOLVED_NAME
      HASH_LIST_PATH = (WORK_PATH + '/' + HASH_LIST_NAME).freeze
      CARTHAGE_PATH = 'Carthage'.freeze
      CARTHAGE_BUILD_PATH = (CARTHAGE_PATH + '/Build').freeze
      CARTHAGE_BUILD_IOS_PATH = (CARTHAGE_BUILD_PATH + '/iOS').freeze
      CARTHAGE_BUILD_IOS_STATIC_PATH = (CARTHAGE_BUILD_IOS_PATH + '/Static').freeze


      #####################################################
      # @!group constant messages
      #####################################################
      CAN_NOT_FIND_FILE = 'Can not find file '.freeze
      SKIP_FETCH_FRAMEWORK = '[Skip fetch framework] '.freeze
      SKIP_STORAGE_FRAMEWORK = '[Skip storage framework] '.freeze


      #####################################################
      # @!group constant suffix
      #####################################################
      SUFFIX_VERSION = '.version'.freeze
      SUFFIX_ZIP = '.zip'.freeze
      SUFFIX_FRAMEWORK = '.framework'.freeze
      SUFFIX_DSYM = '.dSYM'.freeze


      #####################################################
      # @!group constant cmd
      #####################################################
      CART_BOOT = 'carthage bootstrap --platform iOS --cache-builds --new-resolver --configuration Debug'.freeze


      #####################################################
      # @!group constant other
      #####################################################
      BINARY = 'binary'.freeze


      def self.run(params)
          server = params[:server]
          username = params[:username]
          producer = params[:producer]

          ssh_path = username + '@' + server

          if File::exists?(CARTFILE_RESOLVED_PATH)
            # pre validation if user have the right ssh permission to target host
            ssh_connection_check(ssh_path)

            # check if hashlist contains the hash of current resolve file
            shasum = Digest::SHA256.file CARTFILE_RESOLVED_PATH
            UI.header('Start to validate hashList')
            stdout = `ssh #{ssh_path} 'cat #{HASH_LIST_PATH} | grep -c #{shasum}'`

            # current resolve file doesn't have cache, start bootstrap
            if Integer(stdout) == 0
              UI.header('No cache match')
              if producer then progress_producer(ssh_path, shasum) end
              return
            end

            # Hit a cache, start fetch cached framework
            fetch_cache(ssh_path)

            # Clean
            `rm #{CARTHAGE_BUILD_IOS_PATH}/*.bcsymbolmap`

            return
          end

          UI.important("[Skip moss] No Carthage.resolve file found")
      end

      #####################################################
      # @!group private functions
      #####################################################
      private
      def self.progress_producer(ssh_path, shasum)
        if !system(CART_BOOT) then UI.user_error!('Carthage bootstrap failed') end
        UI.header('Start to storage frameworks')
        # Path init
        execute_cmd("rm -rf #{TMP_PATH};mkdir -p #{TMP_PATH}")

        # Get the zip list from remote server
        target_library_list = target_library_list(ssh_path)

        # Storage the frameworks that found in local but not found in remote server
        ((target_library_list + library_list()).uniq { |library| library.name + library.version } - target_library_list).each do |library|

          local_zip_file = TMP_PATH + '/' + library.name + SUFFIX_ZIP
          
          # Find .version file and .framework file and zip them into one zip file
          version_file_path = CARTHAGE_BUILD_PATH + '/.' + library.name + SUFFIX_VERSION
          file_exist_validation(version_file_path)

          frameworks_path = ""
          dsym_files_path = ""

          static_framework_path = CARTHAGE_BUILD_IOS_STATIC_PATH + '/' + library.name + SUFFIX_FRAMEWORK
          static_framework_file_path = static_framework_path + '/' + library.name

          if library.frameworks.nil? then next end
          if library.frameworks.size == 0
            if !File::exists?(static_framework_file_path)
              UI.important(SKIP_STORAGE_FRAMEWORK + "No framework found for " + library.name)
              next
            end

            frameworks_path = static_framework_path
            dsym_files_path = CARTHAGE_BUILD_IOS_STATIC_PATH + '/' + library.name + SUFFIX_FRAMEWORK + SUFFIX_DSYM
          end

          # hash validation stop if not success
          library.frameworks.each do |framework|
            if !framework_validation(framework) then UI.user_error!("framework validation failed for " + framework.name) end

            frameworks_path = frameworks_path + ' ' + CARTHAGE_BUILD_IOS_PATH + '/' + framework.name + SUFFIX_FRAMEWORK
            dsym_files_path = dsym_files_path + ' ' + CARTHAGE_BUILD_IOS_PATH + '/' + framework.name + SUFFIX_FRAMEWORK + SUFFIX_DSYM
          end

          UI.message('Start Zipping ' + library.name + SUFFIX_ZIP)
          execute_cmd("zip #{local_zip_file} #{version_file_path} #{dsym_files_path} -r #{frameworks_path} >> /dev/null 2>&1")

          # storage zip file
          target_zip_file_path = CACHE_PATH + '/' + library.name + '/' + library.version
          target_zip_file = target_zip_file_path + '/' + library.name + SUFFIX_ZIP

          UI.message('Start storage ' + library.name + SUFFIX_ZIP)
          execute_cmd("ssh #{ssh_path} 'mkdir -p #{target_zip_file_path}';scp -p #{local_zip_file} #{ssh_path}:#{target_zip_file}")
        end

        # update hashlist
        UI.message('Start Update HashList!')
        execute_cmd("ssh #{ssh_path} 'echo #{shasum} >> #{HASH_LIST_PATH}'")
        UI.success('Update HashList succeed!')
      end

      private
      def self.fetch_cache(ssh_path)
        UI.header('Hit a cache, start fetch cached frameworks!')
        execute_cmd("rm -rf #{RECEIVE_TMP_PATH};mkdir -p #{RECEIVE_TMP_PATH};mkdir -p #{CACHE_PATH}")

        # Fetch the frameworks that found in remote server but not found in local
        library_list = library_list()
        target_library_list = target_library_list(ssh_path)
        fetch_need_library_list = (target_library_list + library_list) - (target_library_list + library_list).uniq { |library| library.name + library.version }

        (library_list - fetch_need_library_list).each do |library|
          UI.message(SKIP_FETCH_FRAMEWORK + "Remote server does not contain " + library.name)
        end

        fetch_need_library_list.each do |library|

          if !library.commitish.nil? && 
            library.commitish == library.version && 
            !library.frameworks.nil? && 
            ((library.frameworks.size > 0 && library.frameworks.select {|framework| !framework_validation(framework) }.size == 0) || (library.frameworks.size == 0 && static_framework_exists(library)))

            UI.message(SKIP_FETCH_FRAMEWORK + "Valid cache found for " + library.name)
            next
          end

          target_zip_file = CACHE_PATH + '/' + library.name + '/' + library.version + '/' + library.name + SUFFIX_ZIP
          local_zip_file_path = RECEIVE_TMP_PATH + '/' + library.name + '/' + library.version
          local_zip_file = local_zip_file_path + '/' + library.name + SUFFIX_ZIP

          UI.message('Start fetch ' + library.name + SUFFIX_ZIP)
          execute_cmd("mkdir -p #{local_zip_file_path};scp -p #{ssh_path}:#{target_zip_file} #{local_zip_file}")

          UI.message('Start Unzip ' + library.name + SUFFIX_ZIP)
          execute_cmd("unzip -o #{local_zip_file} -d . >> /dev/null 2>&1")
        end
      end

      private
      def self.target_library_list(ssh_path)
        return `ssh #{ssh_path} 'mkdir -p #{CACHE_PATH};find #{CACHE_PATH} -name *.zip'`.to_s.split("\n").map do |path|
          library = Library.new
          library.name = path.split("/").reverse[2]
          library.version = path.split("/").reverse[1]
          library
        end
      end

      private
      def self.static_framework_exists(library)

        static_framework_file_path = CARTHAGE_BUILD_IOS_STATIC_PATH + '/' + library.name + SUFFIX_FRAMEWORK + '/' + library.name
        if File::exists?(static_framework_file_path) then return true end

        return false
      end

      # validate framework exists and with the right shasum
      private
      def self.framework_validation(framework)
        framework_path = CARTHAGE_BUILD_IOS_PATH + '/' + framework.name + SUFFIX_FRAMEWORK
        framework_file_path = framework_path + '/' + framework.name
        dsym_file_path = CARTHAGE_BUILD_IOS_PATH + '/' + framework.name + SUFFIX_FRAMEWORK + SUFFIX_DSYM

        if !File::exists?(framework_file_path)
          UI.message(CAN_NOT_FIND_FILE + framework_file_path)
          return false
        end

        if !File::exists?(dsym_file_path)
          UI.message(CAN_NOT_FIND_FILE + framework_file_path)
          return false
        end

        framework_shasum = Digest::SHA256.file framework_file_path
        if framework_shasum.to_s != framework.hash
          UI.message('The hash of ' + framework_file_path + ' is [' + framework_shasum.to_s + '] which is not match the value [' + framework.hash + '] in .version file')
          return false
        end

        return true
      end

      private
      def self.ssh_connection_check(ssh_path)
        if !system("ssh -o BatchMode=yes -o ConnectTimeout=5 #{ssh_path} echo 0 2>&1")
          UI.user_error!("Can not open a ssh connection to #{ssh_path} please make sure you have the right premission and try to execute \n'ssh-copy-id -i ~/.ssh/id_rsa.pub #{ssh_path}' before you run moss")
        end
      end

      private
      def self.execute_cmd(cmd)
        if !system(cmd) then UI.user_error!(cmd + ' failed ') end
      end

      private
      def self.file_exist_validation(path)
        if !File::exists?(path) then UI.user_error!(CAN_NOT_FIND_FILE + path) end
      end

      private
      def self.library_list()
       return IO.readlines(CARTFILE_RESOLVED_PATH).map{ |line|

          begin
            type = line.split[0]
            library_name = line.split[1].delete('"').split('/').last.split('.').first
            library_version = line.split[2].delete('"')
          rescue
            UI.user_error!('[File read file] ' + CARTFILE_RESOLVED_PATH + ' Please make sure the resolved file is genereted by cathage.')
          end

          library_commitish = nil
          library_frameworks = nil

          version_file_path = CARTHAGE_BUILD_PATH + '/.' + library_name + SUFFIX_VERSION

          # TODO
          # Need to support binary type cache
          if type == BINARY
            UI.important("[No support for Binary type] " + library_name)

            next
          end

          if File::exists?(version_file_path)

            json = File.read(version_file_path)
            obj = JSON.parse(json)

            library_commitish = obj['commitish']
            node_iOS = obj['iOS']
            
            if library_commitish.nil? then UI.important('[No commitish node found] ' + version_file_path) end
            if node_iOS.nil? then UI.important('[No iOS node found] ' + version_file_path)
            elsif node_iOS.size == 0
              UI.important('[No frameworks found] ' + version_file_path)
              # TODO 
              # Need to support static Library
              # library_frameworks = []
            else
              library_frameworks = node_iOS.map{ |node|

                node_iOS_name = node['name']
                if node_iOS_name.nil?
                  UI.important('[No name node found] ' + version_file_path)
                  next
                end
                node_iOS_hash = node['hash']
                if node_iOS_hash.nil?
                  UI.important('[No hash node found] ' + version_file_path)
                  next
                end

                framework = Framework.new
                framework.name = node_iOS_name
                framework.hash = node_iOS_hash
                framework
              }.compact
            end
          end

          library = Library.new
          library.name = library_name
          library.version = library_version
          library.commitish = library_commitish
          library.frameworks = library_frameworks

          library
        }.compact
      end

      def self.description
        "moss is a tool that allows developers on Apple platforms to use any frameworks as a shared cache for frameworks built with Carthage."
      end

      def self.authors
        ["Shaggon du"]
      end

      def self.return_value
        nil
      end

      def self.details
        # Optional:
        "moss is a tool that allows developers on Apple platforms to use any frameworks as a shared cache for frameworks built with Carthage."
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :server,
            env_name: 'MOSS_SERVER',
            optional: false,
            description: 'The Server Name or the ip address which store the cache of the frameworks'),
          FastlaneCore::ConfigItem.new(key: :username,
            env_name: 'MOSS_USERNAME',
            optional: false,
            description: 'The username use to use scp command'),
          FastlaneCore::ConfigItem.new(key: :producer,
            is_string: false,
            env_name: 'MOSS_PRODUCER',
            optional: true,
            description: 'If true, the executor will act as a producer, not only use the cached frameworks but also produce it',
            default_value: false)
        ]
      end

      def self.is_supported?(platform)
        [:ios].include?(platform)
      end

      def self.example_code
        [
          'moss'
        ]
      end
    end
  end
end

class Library
    attr_accessor:name, :frameworks, :commitish, :version
end

class Framework
    attr_accessor:name, :hash
end
