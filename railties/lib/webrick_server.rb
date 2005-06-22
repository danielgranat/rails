# Donated by Florian Gross

require 'webrick'
require 'cgi'
require 'stringio'

include WEBrick

ABSOLUTE_RAILS_ROOT = File.expand_path(RAILS_ROOT)

class CGI
  def stdinput
    @stdin || $stdin
  end
  
  def stdinput=(input)
    @stdin = input
  end

  def env_table
    @env_table || ENV
  end

  def env_table=(table)
    @env_table = table
  end
end

class DispatchServlet < WEBrick::HTTPServlet::AbstractServlet
  REQUEST_MUTEX = Mutex.new

  def self.dispatch(options = {})
    Socket.do_not_reverse_lookup = true # patch for OS X

    server = WEBrick::HTTPServer.new(:Port => options[:port].to_i, :ServerType => options[:server_type], :BindAddress => options[:ip])
    server.mount('/', DispatchServlet, options)

    trap("INT") { server.shutdown }

    require File.join(@server_options[:server_root], "..", "config", "environment") unless defined?(RAILS_ROOT)
    require "dispatcher"

    server.start
  end

  def initialize(server, options)
    @server_options = options
    @file_handler = WEBrick::HTTPServlet::FileHandler.new(server, options[:server_root])
    Dir.chdir(ABSOLUTE_RAILS_ROOT)
    super
  end

  def service(req, res)
    begin
      unless handle_file(req, res)
        REQUEST_MUTEX.lock unless RAILS_ENV == 'production'
        unless handle_dispatch(req, res)
          raise WEBrick::HTTPStatus::NotFound, "`#{req.path}' not found."
        end
      end
    ensure
      unless RAILS_ENV == 'production'
        REQUEST_MUTEX.unlock if REQUEST_MUTEX.locked?
      end
    end
  end

  def handle_file(req, res)
    begin
      req = req.dup
      path = req.path.dup

      # Add .html if the last path piece has no . in it
      path << '.html' if path != '/' && (%r{(^|/)[^./]+$} =~ path) 
      path.gsub!('+', ' ') # Unescape + since FileHandler doesn't do so.

      req.instance_variable_set(:@path_info, path) # Set the modified path...
      
      @file_handler.send(:service, req, res)
      return true
    rescue HTTPStatus::PartialContent, HTTPStatus::NotModified => err
      res.set_error(err)
      return true
    rescue => err
      return false
    end
  end

  def handle_dispatch(req, res, origin = nil)    
    data = StringIO.new
    Dispatcher.dispatch(create_cgi(req, origin), ActionController::CgiRequest::DEFAULT_SESSION_OPTIONS, data)

    header, body = extract_header_and_body(data)
    assign_status(res, header)
    res.cookies.concat(header.delete('set-cookie'))
    header.each { |key, val| res[key] = val.join(", ") }
    
    res.body = body
    return true
  rescue => err
    p err, err.backtrace
    return false
  end
  
  private
    def create_cgi(req, origin)
      cgi = CGI.new
      cgi.env_table = create_env_table(req, origin)
      cgi.stdinput  = req.body || ""
      return cgi
    end

    def create_env_table(req, origin)
      env = req.meta_vars.clone
      env.delete "SCRIPT_NAME"
      env["QUERY_STRING"] = req.request_uri.query
      env["REQUEST_URI"]  = origin if origin
      return env
    end
    
    def extract_header_and_body(data)
      data.rewind
      data = data.read

      raw_header, body = *data.split(/^[\xd\xa]+/on, 2)
      header = WEBrick::HTTPUtils::parse_header(raw_header)
      
      return header, body
    end

    def assign_status(res, header)
      if /^(\d+)/ =~ header['status'][0]
        res.status = $1.to_i
        header.delete('status')
      end
    end
end
