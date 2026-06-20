# frozen_string_literal: true

module TypesenseModel
  class Configuration
    attr_accessor :api_key, :host, :port, :protocol, :connection_timeout_seconds

    def initialize
      @api_key = nil
      @host = 'localhost'
      @port = 8108
      @protocol = 'http'
      @connection_timeout_seconds = 5
      @client_mutex = Mutex.new
    end

    def client
      return @client if @client

      @client_mutex.synchronize do
        @client ||= Typesense::Client.new(
          api_key: api_key,
          nodes: [{
            host: host,
            port: port,
            protocol: protocol
          }],
          connection_timeout_seconds: connection_timeout_seconds
        )
      end
    end
  end
end
