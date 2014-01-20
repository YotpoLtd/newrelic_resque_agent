#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
require "newrelic_plugin"

require 'resque'
require 'redis'

require 'ridley'

module NewRelicResqueAgent
  
  VERSION = '1.0.2'

  class Agent < NewRelic::Plugin::Agent::Base

    agent_guid "com.yotpo.resque"
    agent_config_options :redis, :namespace, :hostname
    agent_version NewRelicResqueAgent::VERSION
    agent_human_labels("Resque_Development") { ident }
    
    attr_reader :ident

    def setup_metrics
      @total_failed = NewRelic::Processor::EpochCounter.new
      @processed    = NewRelic::Processor::EpochCounter.new
    end

    def poll_cycle
      if redis.nil?
        raise "Redis connection URL "
      end

      begin
        Resque.redis = redis
        Resque.redis.namespace = namespace unless namespace.nil?
        info = Resque.info
        
        report_metric "Workers/Working", "Workers",           info[:working]
        report_metric "Workers/Total", "Workers",             info[:workers]
        report_metric "MinWorkersCritical", "MinWorkersCritical",   info[:workers] < 10 ? 1: 0
        report_metric "MinWorkersWarning", "MinWorkersWarning",   info[:workers] < 50 ? 1: 0
        report_metric "Jobs/Pending", "Jobs",                 info[:pending]
        report_metric "Jobs/Rate/Processed", "Jobs/Second",   @processed.process(info[:processed])
        report_metric "Jobs/Rate/Failed", "Jobs/Second",      @total_failed.process(info[:failed])
        report_metric "Queues", "Queues",                     info[:queues]
        report_metric "Jobs/Failed", "Jobs",                  info[:failed] || 0
        report_metric 'Redis/Alive', 'Boolean',               1
        

      rescue Redis::TimeoutError
        report_metric 'Redis/Alive', 'Boolean',               0
      rescue  Redis::CannotConnectError, Redis::ConnectionError
        report_metric 'Redis/Alive', 'Boolean',               0
      rescue Errno::ECONNRESET
        report_metric 'Redis/Alive', 'Boolean',               0
      end
    end

  end
  
  # Register and run the agent
  def self.run

    config = NewRelic::Plugin::Config.config.options
    config['agents'] = get_agents(config['chef']['server_url'], config['chef']['client_name'], config['chef']['client_key'], config['chef']['environment'] || 'production')
    NewRelic::Plugin::Config.config_yaml = YAML::dump(config)

    NewRelic::Plugin::Config.config.agents.keys.each do |agent|
      NewRelic::Plugin::Setup.install_agent agent, NewRelicResqueAgent
    end

    #
    # Launch the agent (never returns)
    #
    NewRelic::Plugin::Run.setup_and_run
  end

  def self.get_agents(server_url, client_name, client_key, environment = 'production')
    ridley = ::Ridley.new(
        server_url: server_url,
        client_name: client_name,
        client_key: client_key
    )
    servers = ridley.search(:node, "environment:#{environment} AND role:yotpo_redis")
    agents = {}
    servers.each do |node|
      port = 6379
      unless node.chef_attributes.yotpo_server.redis_master
        port += 1
      end
      node.chef_attributes.yotpo_server['yotpo-redis'].instances.times do
        ip = node.automatic_attributes.fqdn
        agents["#{ip}_#{port}"] = {'redis' => "#{ip}:#{port}"}
        port += 1
      end
    end
    return agents
  end
end