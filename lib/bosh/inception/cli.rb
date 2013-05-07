require "thor"
require "highline"
require "fileutils"
require "json"

# for the #sh helper
require "rake"
require "rake/file_utils"

require "escape"
require "bosh/inception/cli_helpers/display"
require "bosh/inception/cli_helpers/provider"
require "bosh/inception/cli_helpers/settings"
require "bosh/inception/cli_helpers/prepare_deploy_settings"

module Bosh::Inception
  class Cli < Thor
    include Thor::Actions
    include FileUtils
    include Bosh::Inception::CliHelpers::Display
    include Bosh::Inception::CliHelpers::Provider
    include Bosh::Inception::CliHelpers::Settings
    include Bosh::Inception::CliHelpers::PrepareDeploySettings

    desc "deploy", "Create/upgrade a Bosh Inception VM"
    def deploy
      migrate_old_settings
      prepare_deploy_settings
      validate_deploy_settings
      perform_deploy
      converge_cookbooks
    end

    desc "destroy", "Destroy target Bosh Inception VM"
    def destroy
      migrate_old_settings
      error "Not implemented yet"
    end

    desc "ssh [COMMAND]", "Open an ssh session to the inception VM [do nothing if local machine is the inception VM]"
    long_desc <<-DESC
      If a command is supplied, it will be run, otherwise a session will be opened.
    DESC
    def ssh(cmd=nil)
      migrate_old_settings
      run_ssh_command_or_open_tunnel(cmd)
    end

    desc "tmux", "Open an ssh (with tmux) session to the inception VM [do nothing if local machine is inception VM]"
    long_desc <<-DESC
      Opens a connection using ssh and attaches to the most recent tmux session;
      giving you persistance across disconnects.
    DESC
    def tmux
      migrate_old_settings
      run_ssh_command_or_open_tunnel(["-t", "tmux attach || tmux new-session"])
    end

    no_tasks do
      # if git.name/git.email not provided, load it in from local ~/.gitconfig
      # provision public IP address for inception VM if not allocated one
      def prepare_deploy_settings
        header "Preparing deployment settings"
        update_git_config
        provision_or_reuse_public_ip_address_for_inception unless settings.exists?("inception.ip_address")
        recreate_key_pair_for_inception unless settings.exists?("inception.key_pair.private_key")
        recreate_private_key_file_for_inception
      end

      # Required settings:
      # * git.name
      # * git.email
      def validate_deploy_settings
        begin
          settings.git.name
          settings.git.email
        rescue Settingslogic::MissingSetting => e
          error "Please setup local git user.name & user.email config; or specify git.name & git.email in settings.yml"
        end

        begin
          settings.provider.name
          settings.provider.region
          settings.provider.credentials
        rescue Settingslogic::MissingSetting => e
          error "Wooh there, we need provider.name, provider.region, provider.credentials in settings.yml to proceed."
        end

        begin
          settings.inception.ip_address
          settings.inception.key_pair.name
          settings.inception.key_pair.private_key
        rescue Settingslogic::MissingSetting => e
          error "Wooh there, we need inception.ip_address, inception.key_pair.name, & inception.key_pair.private_key in settings.yml to proceed."
        end
      end

      def perform_deploy
        header "Provision inception VM"
        server = InceptionServer.new(provider_client, settings.inception, settings_ssh_dir)
        server.create
      ensure
        # after any error handling, still save the current InceptionServer state back into settings.inception
        settings["inception"] = server.export_attributes
        save_settings!
      end

      # Perform converge chef cookbooks upon Inception VM
      def converge_cookbooks
        header "Prepare inception VM"
        server = InceptionServer.new(provider_client, settings.inception, settings_ssh_dir)
        user_host = server.user_host
        key_path = server.private_key_path
        attributes = cookbook_attributes_for_inception.to_json
        sh %Q{knife solo cook #{user_host} -i #{key_path} -j '#{attributes}' -r 'bosh_inception'}
      end

      def cookbook_attributes_for_inception
        {
          "disk" => {
            "mounted" => true,
            "device" => settings.inception.provisioned.disk_device.internal
          },
          "git" => {
            "name" => settings.git.name,
            "email" => settings.git.email
          },
          "user" => {
            "username" => settings.inception.provisioned.username
          }
        }
      end

      def run_ssh_command_or_open_tunnel(cmd)
        recreate_private_key_file_for_inception
        unless settings.exists?("inception.provisioned.host")
          exit "Inception VM has not finished launching; run to complete: bosh-inception deploy"
        end

        server = InceptionServer.new(provider_client, settings.inception, settings_ssh_dir)
        username = settings.inception.provisioned.username
        host = settings.inception.provisioned.host
        result = system Escape.shell_command(["ssh", "-i", server.private_key_path, "#{username}@#{host}", cmd].flatten.compact)
        exit result
      end
    end
  end
end