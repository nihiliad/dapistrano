Capistrano::Configuration.instance(:must_exist).load do

  require 'capistrano/recipes/deploy/scm'
  require 'capistrano/ext/multistage'
  require 'railsless-deploy'

  # =========================================================================
  # These variables may be set in the client capfile if their default values
  # are not sufficient.
  # =========================================================================


  set :default_stage, "development"
  set :stages, %w(production development staging)
  set :scm, :git
  set :branch, "master"
  set :drush_command_path, "drush"
  set :group_writable, true
  set :use_sudo, false

  set(:deploy_to) { "/var/www/#{application}" }
  set :shared_children, ['files', 'private']
  set :core_files_to_remove, [
    'INSTALL.mysql.txt',
    'INSTALL.pgsql.txt',
    'CHANGELOG.txt',
    'COPYRIGHT.txt',
    'INSTALL.txt',
    'LICENSE.txt',
    'MAINTAINERS.txt',
    'UPGRADE.txt'
  ]

  # files that frequently require local customization
  set :override_core_files, ['robots.txt', '.htaccess']

  after "deploy:update_code", "drupal:update_code", "drupal:symlink_shared", "drupal:clear_apc", "drush:cache_clear"

  namespace :deploy do
    desc <<-DESC
      Prepares one or more servers for deployment. Before you can use any \
      of the Capistrano deployment tasks with your project, you will need to \
      make sure all of your servers have been prepared with `cap deploy:setup'. When \
      you add a new server to your cluster, you can easily run the setup task \
      on just that server by specifying the HOSTS environment variable:

        $ cap HOSTS=new.server.com deploy:setup

      It is safe to run this task on servers that have already been set up; it \
      will not destroy any deployed revisions or data.
    DESC
    task :setup, :except => { :no_release => true } do
      dirs = [deploy_to, releases_path, shared_path].join(' ')
      run "#{try_sudo} mkdir -p #{releases_path} #{shared_path}"
      run "#{try_sudo} chown -R #{user}:#{runner_group} #{deploy_to}"
      sub_dirs = shared_children.map { |d| File.join(shared_path, d) }
      run "#{try_sudo} mkdir -p #{sub_dirs.join(' ')}"
      run "#{try_sudo} chown -R #{user}:#{runner_group} #{shared_path}"
      run "#{try_sudo} chmod -R 2775 #{shared_path}"
    end

    # removed non rails stuff, ensure group writabilty
    task :finalize_update, :roles => :web, :except => { :no_release => true } do
      run "chmod -R g+w #{latest_release}" if fetch(:group_writable, true)
    end
  end

  namespace :drupal do

    task :update_code do
      # Locate the make file and run it
      args = fetch(:make_args, "")
      run "ls #{latest_release} | grep \.make" do |channel, stream, make_file|
        run "cd #{latest_release}; #{drush_command_path} make #{args} #{make_file} ."
      end
      core_files = core_files_to_remove.map { |cf| File.join(latest_release, cf) }
      run "rm #{core_files.join(' ')}"
    end

    desc "Symlink settings and files to shared directory. This allows the settings.php and \
      and sites/default/files directory to be correctly linked to the shared directory on a new deployment."
    task :symlink_shared do
      ["files", "private", "settings.php"].each do |asset|
        run "rm -rf #{latest_release}/#{asset} && ln -nfs #{shared_path}/#{asset} #{latest_release}/sites/default/#{asset}"
      end
      override_core_files.each do |file|
        run "rm #{latest_release}/#{file} && ln -nfs #{shared_path}/#{file} #{latest_release}/#{file}"
      end
    end

    # Prevent apc memory allocation issues by clearing the apc cache
    task :clear_apc do
      puts 'Clearing APC Cache to prevent memory allocation errors'
      script = <<-STRING
      <?php
      apc_clear_cache();
      apc_clear_cache('user');
      apc_clear_cache('opcode');
      STRING
      put script, "#{latest_release}/apc_clear.php"
      run "curl #{application_url}/apc_clear.php"
      # run "rm #{latest_release}/apc_clear.php"
    end
  end

  namespace :drush do

    desc "Run Drupal database migrations if required"
    task :updatedb, :on_error => :continue do
      :site_offline
      run "#{drush_command_path} -r #{latest_release} updatedb -y"
      :cache_clear
      :site_online
    end

    desc "Clear the drupal cache"
    task :cache_clear, :on_error => :continue do
      run "#{drush_command_path} -r #{latest_release} cc all"
    end

    desc "Set the site offline"
    task :site_offline, :on_error => :continue do
      run "#{drush_command_path} -r #{latest_release} vset site_offline 1 -y"
      run "#{drush_command_path} -r #{latest_release} vset maintenance_mode 1 -y"
    end

    desc "Set the site online"
    task :site_online, :on_error => :continue do
      run "#{drush_command_path} -r #{latest_release} vset site_offline 0 -y"
      run "#{drush_command_path} -r #{latest_release}} vset maintenance_mode 0 -y"
    end

  end
end