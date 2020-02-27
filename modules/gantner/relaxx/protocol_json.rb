module Gantner; end
module Gantner::Relaxx; end

require "openssl"
require "openssl/cipher"
require "securerandom"
require "base64"
require "json"
require "set"

class Gantner::Relaxx::ProtocolJSON
  include ::Orchestrator::Constants

  # Discovery Information
  tcp_port 8237
  descriptive_name "Gantner GAT Relaxx JSON API"
  generic_name :Lockers

  # Communication settings
  tokenize delimiter: "\x03"

  def on_load
    @authenticated = false
    @password = "GAT"
    @locker_ids = Set.new
    @lockers_in_use = Set.new
    on_update
  end

  def on_update
    @password = setting(:password) || "GAT"
  end

  def connected
    self[:authenticated] = @authenticated = false
    request_auth_string

    schedule.every("40s") do
      logger.debug "-- maintaining connection"
      @authenticated ? keep_alive : request_auth_string
    end
  end

  def disconnected
    schedule.clear
  end

  def keep_alive
    send_frame({
      Caption: "KeepAliveRequest",
      Id: new_request_id
    }, priority: 0)
  end

  def request_auth_string
    send_frame({
      Caption: "AuthenticationRequestA",
      Id: new_request_id
    }, priority: 9998)
  end

  def open_locker(locker_number, locker_group = nil)
    set_open_state(true, locker_number, locker_group)
  end

  def close_locker(locker_number, locker_group = nil)
    set_open_state(false, locker_number, locker_group)
  end

  def set_open_state(open, locker_number, locker_group = nil)
    action = open ? "0" : "1"
    request = {
      Caption: "ExecuteLockerActionRequest",
      Id: new_request_id,
      Action: action
    }
    if locker_number.include?("-")
      request[:LockerId] = locker_number
    else
      request[:LockerNumber] = locker_number
    end
    request[:LockerGroupId] = locker_group if locker_group
    send_frame(request)
  end

  def query_lockers(free_only = false)
    send_frame({
      Caption: "GetLockersRequest",
      Id: new_request_id,
      FreeLockersOnly: free_only,
      PersonalLockersOnly: false
    })
  end

  LOCKER_STATE = {
    0 => :unknown,
    1 => :disabled,
    2 => :free,
    3 => :in_use,
    4 => :locked,
    5 => :alarmed,
    6 => :in_use_expired,
    7 => :conflict
  }

  def received(data, resolve, command)
    # Ignore the framing bytes
    data = data[1..-1]
    logger.debug { "Gantner Relaxx sent: #{data}" }
    json = JSON.parse(data)

    return parse_notify(json["Caption"], json) if json["IsNotification"]

    # Check result of the request
    result = json["Result"]
    return :abort if result["Cancelled"]
    return :abort if !result["Successful"]

    # Process response
    case json["Caption"]
    when "AuthenticationResponseA"
      logged_in = json["LoggedIn"]
      self["authenticated"] = @authenticated = logged_in
      return :success if logged_in
      login(json["AuthenticationString"])

    when "AuthenticationResponseB"
      logged_in = json["LoggedIn"]
      self["authenticated"] = @authenticated = logged_in
      if logged_in
        logger.debug "authentication success"

        # Obtain the list of lockers and their current state
        query_lockers if @locker_ids.empty?
      else
        logger.warn "authentication failure - please check credentials"
      end

    when "GetLockersResponse"
      lockers = json["Lockers"]
      lockers.each do |locker|
        locker_id = locker["RecordId"]
        @locker_ids << locker_id

        if LOCKER_STATE[locker["State"]] == :free
          @lockers_in_use.delete(locker_id)
        else
          @lockers_in_use << locker_id
          self["locker_#{locker_id}"] = locker["CardUIDInUse"]
        end
      end
      self[:locker_ids] = @locker_ids.to_a
      self[:lockers_in_use] = @lockers_in_use.to_a

    when "CommandNotSupportedResponse"
      logger.warn "Command not supported!"
      return :abort
    end

    return :success
  end

  private

  # Converts the data to bytes and wraps it into a frame
  def send_frame(data, **options)
    logger.debug { "requesting #{data[:Caption]}, id #{data[:Id]}" }
    send "\x02#{data.to_json}\x03", **options
  end

  def new_request_id
    SecureRandom.uuid
  end

  def login(authentication_string)
    decipher = OpenSSL::Cipher::AES.new(256, :CBC).decrypt
    decipher.padding = 1

    # LE for little endian and avoids a byte order mark
    password = @password.encode(Encoding::UTF_16LE).force_encoding("BINARY")
    decipher.key = "#{password}#{"\x00" * (32 - password.bytesize)}"
    decipher.iv = "#{password}#{"\x00" * (16 - password.bytesize)}"

    plain = decipher.update(Base64.decode64(authentication_string)) + decipher.final
    decrypted = plain.force_encoding(Encoding::UTF_16LE)

    send_frame({
      Caption: "AuthenticationRequestB",
      Id: new_request_id,
      AuthenticationString: decrypted
    }, priority: 9999)
  end

  def parse_notify(caption, json)
    case caption
    when "LockerEventNotification"
      locker = json["Locker"]
      update_locker_state(LOCKER_STATE[locker["State"]] != :free, locker["RecordId"], locker["CardUIDInUse"])
    else
      logger.debug { "ignoring event: #{caption}" }
    end
    nil
  end

  def update_locker_state(in_use, locker_id, card_id)
    @locker_ids << locker_id
    if in_use
      @lockers_in_use << locker_id
    else
      @lockers_in_use.delete(locker_id)
    end
    self["locker_#{locker_id}"] = card_id
    self[:locker_ids] = @locker_ids.to_a
    self[:lockers_in_use] = @lockers_in_use.to_a
  end
end
