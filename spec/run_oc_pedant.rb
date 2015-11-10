#!/usr/bin/env ruby
require 'bundler'
require 'bundler/setup'

require 'chef_zero/server'
require 'rspec/core'

def start_server(chef_repo_path)
  require 'chef/version'
  require 'chef/config'
  require 'chef/chef_fs/config'
  require 'chef/chef_fs/chef_fs_data_store'
  require 'chef_zero/server'

  Dir.mkdir(chef_repo_path) if !File.exists?(chef_repo_path)

  # 11.6 and below had a bug where it couldn't create the repo children automatically
  if Chef::VERSION.to_f < 11.8
    %w(clients cookbooks data_bags environments nodes roles users).each do |child|
      Dir.mkdir("#{chef_repo_path}/#{child}") if !File.exists?("#{chef_repo_path}/#{child}")
    end
  end

  # Start the new server
  Chef::Config.repo_mode = 'everything'
  Chef::Config.chef_repo_path = chef_repo_path
  Chef::Config.versioned_cookbooks = true
  chef_fs = Chef::ChefFS::Config.new.local_fs

  data_store = Chef::ChefFS::ChefFSDataStore.new(chef_fs)
  data_store = ChefZero::DataStore::V1ToV2Adapter.new(data_store, 'pedant-testorg')
  data_store = ChefZero::DataStore::DefaultFacade.new(data_store, 'pedant-testorg', false)

  server = ChefZero::Server.new(
    port: 8889,
    data_store: data_store,
    single_org: false,
    #log_level: :debug
  )
  server.start_background
  server
end

tmpdir = nil

begin
  if ENV['FILE_STORE']
    require 'tmpdir'
    require 'chef_zero/data_store/raw_file_store'
    tmpdir = Dir.mktmpdir
    data_store = ChefZero::DataStore::RawFileStore.new(tmpdir, true)
    data_store = ChefZero::DataStore::DefaultFacade.new(data_store, false, false)
    server = ChefZero::Server.new(:port => 8889, :single_org => false, :data_store => data_store)
    server.start_background

  elsif ENV['CHEF_FS']
    require 'tmpdir'
    tmpdir = Dir.mktmpdir
    server = start_server(tmpdir)

  else
    server = ChefZero::Server.new(:port => 8889, :single_org => false)#, :log_level => :debug)
    server.start_background
  end

  require 'rspec/core'
  require 'pedant'
  require 'pedant/organization'

  # Pedant::Config.rerun = true

  Pedant.config.suite = 'api'
  Pedant.config.internal_server = Pedant::Config.search_server = 'http://localhost:8889'

  # see dummy_endpoint.rb.
  Pedant.config.search_commit_url = "/dummy"
  Pedant::Config.search_url_fmt = "/dummy?fq=+X_CHEF_type_CHEF_X:%{type}&q=%{query}&wt=json"

  Pedant.config[:config_file] = 'spec/support/oc_pedant.rb'

  # "the goal is that only authorization, authentication and validation tests are turned off" - @jkeiser
  Pedant.setup([
    '--skip-knife',
    '--skip-keys',
    '--skip-controls',
    '--skip-acl',
    '--skip-validation',
    '--skip-authentication',
    '--skip-authorization',
    '--skip-omnibus',
    '--skip-usags',
    '--exclude-internal-orgs',
    '--skip-headers',

    # Chef 12 features not yet 100% supported by Chef Zero
    '--skip-cookbook-artifacts',
    '--skip-containers',
    '--skip-api-v1'

  ])

  result = RSpec::Core::Runner.run(Pedant.config.rspec_args)

  server.stop if server.running?
ensure
  FileUtils.remove_entry_secure(tmpdir) if tmpdir
end

exit(result)
