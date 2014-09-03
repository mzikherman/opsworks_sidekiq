# Adapted from unicorn::rails: https://github.com/aws/opsworks-cookbooks/blob/master/unicorn/recipes/rails.rb

include_recipe "opsworks_sidekiq::service"

# setup sidekiq service per app
node[:deploy].each do |application, deploy|

  if deploy[:application_type] != 'rails'
    Chef::Log.debug("Skipping opsworks_sidekiq::setup application #{application} as it is not a Rails app")
    next
  end

  opsworks_deploy_user do
    deploy_data deploy
  end

  opsworks_deploy_dir do
    user deploy[:user]
    group deploy[:group]
    path deploy[:deploy_to]
  end

  # Allow deploy user to restart workers
  template "/etc/sudoers.d/#{deploy[:user]}" do
    mode 0440
    source "sudoer.erb"
    variables :user => deploy[:user]
  end

  if node[:sidekiq][application]

    workers = node[:sidekiq][application].to_hash.reject {|k,v| k.to_s =~ /restart_command|syslog/ }
    config_directory = "#{deploy[:deploy_to]}/shared/config"

    workers.each do |worker, options|

      # Convert attribute classes to plain old ruby objects
      config = options[:config] ? options[:config].to_hash : {}

      Chef::Log.info("Config is #{config}")
      config.each do |k, v|
        Chef::Log.info("The value of k is #{k}")
        Chef::Log.info("The value of v is #{v}")
        Chef::Log.info("The class of k is #{k.class}")
        Chef::Log.info("The class of v is #{v.class}")
        Chef::Log.info("The inspect of k is #{k.inspect}")
        Chef::Log.info("The inspect of v is #{v.inspect}")
        case v
        when Chef::Node::ImmutableArray
          config[k] = v.to_a
        when Chef::Node::ImmutableMash
          config[k] = v.to_hash
        end
      end
      Chef::Log.info("Config is #{config}")
      # YOLO
      v = config["queues"]
      Chef::Log.info("Class of v is #{v.class}")
      config["queues"] = v.to_a
      v = config["queues"]
      Chef::Log.info("Class of v after is #{v.class}")
      # Generate YAML string
      yaml = YAML::dump(config)

      # Convert YAML string keys to symbol keys for sidekiq while preserving
      # indentation. (queues: to :queues:)
      yaml = yaml.gsub(/^(\s*)([^:][^\s]*):/,'\1:\2:')

      (options[:process_count] || 1).times do |n|
        file "#{config_directory}/sidekiq_#{worker}#{n+1}.yml" do
          mode 0644
          action :create
          content yaml
        end
      end
    end

    template "#{node[:monit][:conf_dir]}/sidekiq_#{application}.monitrc" do
      mode 0644
      source "sidekiq_monitrc.erb"
      variables({
        :deploy => deploy,
        :application => application,
        :workers => workers,
        :syslog => node[:sidekiq][application][:syslog]
      })
      notifies :reload, resources(:service => "monit"), :immediately
    end

  end
end
