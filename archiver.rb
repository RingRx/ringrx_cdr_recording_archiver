#!/usr/bin/ruby
# frozen_string_literal: true

require 'httparty'
require 'httmultiparty'
require 'json'
require 'yaml'
require 'logger'
require 'pp'
require 'fileutils'

####################################################################
### Defining functions
####################################################################

  def init
    @conffile = YAML.load_file('./archiver.conf')

    dest_dir = @conffile['destination_dir']
    Dir.mkdir(dest_dir) unless Dir.exist?(dest_dir)

    log_dir = "logs/"
    Dir.mkdir(log_dir) unless Dir.exist?(log_dir)

    cdr_dir = @conffile['cdrdir']
    Dir.mkdir(cdr_dir) unless Dir.exist?(cdr_dir)

    tmp_dir = @conffile['tempdir']
    Dir.mkdir(tmp_dir) unless Dir.exist?(tmp_dir)

    logfile = "logs/#{@conffile['logfile']}"
    logfilerotation = (@conffile['logfilerotation']).to_s

    $LOG = Logger.new(logfile, logfilerotation)
    $LOG.level = Logger::WARN
  end

  def auth
    body = {}
    body[:username] = @conffile['acct_username']
    body[:password] = @conffile['acct_password']

    response = HTTParty.post("#{@conffile['portal_url']}/auth/token",
      body: body.to_json,
      timeout: 10,
      headers: { 'Content-Type' => 'application/json' },
      verify: false )
    return response
  end

  def request_headers(token)
    headers = {}
    headers['Content-Type'] = "application/json"
    headers['Authorization'] = token
    return headers
  end

  def fetch_cdrs(token)
    url = "#{@conffile['portal_url']}/cdrs?getAll=true"
    response = HTTParty.get(url,
      timeout: 10,
      headers: request_headers(token),
      verify: false )
    return response
  end

  def fetch_recording(cdrid)
    url = "#{@conffile['portal_url']}/cdrs/#{cdrid}/recording"
    response = HTTParty.get(url,
      :timeout => 10,
      :headers => request_headers(token),
      :verify => false )
    return response
  end

  def file_name(msg)
    if msg["message_type"] == "message"
      file_ext = "txt"
    elsif msg["message_type"] == "fax"
      file_ext = msg["fax"].split(".").last
    elsif msg["message_type"] == "voicemail"
      file_ext = msg["voicemail"].split(".").last
    end
    file_str = "#{@conffile['destination_filename']}.#{file_ext}"
    output = file_str.gsub("{id}", msg["id"]).gsub("{caller}", msg["caller"]).gsub("{called}", msg["called"]).gsub("{created}", msg["created_at"]).gsub(" ", "_").gsub("{mailbox}", msg["mailbox"]).gsub("{type}", msg["message_type"]).gsub(':', '.')
    return output
  end

  def cdr_ids
    file = File.open(File.join('db', 'cdrids'), 'r')
    cdrids = file.readlines.map(&:chomp)
    file.close
    return cdrids
  end
  
  def cdr_file(cdr)
    filename = File.join(@conffile['cdrdir'], cdr['start_time'].split(' ').first, ".csv")
    unless File.exists?(filename)
      file = File.open(filename, wb)
      
    end 
  end

  def write_cdr(call)
    puts call['start_time'].split(' ').first
  end

####################################################################
### Main app logic
####################################################################

puts "Starting up"
init
auth_resp = auth

puts auth_resp.code
puts auth_resp['access_token']

if auth_resp.code == 200
  puts "auth succeeded..setting auth token to #{auth_resp['access_token']}"
  @auth_token = auth_resp['access_token']
end

if @auth_token
  $LOG.warn "Performing cdr fetch operation"
  puts "received auth token. Good to proceed"
  puts "Fetching cdrs"

  cdrs = fetch_cdrs(@auth_token).parsed_response
  cdrs.sort_by { |c| c['id'] }.each do |cdr|
    write_cdr(cdr)
  end
else
  $LOG.warn "Authentication failed unable to fetch messages"
  puts "no auth token..stopping"
end

