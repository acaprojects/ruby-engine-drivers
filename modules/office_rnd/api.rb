require "uri"

module OfficeRnd; end

# Documentation: https://developer.officernd.com/#resources

class OfficeRnd::API
  include ::Orchestrator::Constants
  include ::Orchestrator::Transcoder

  # Discovery Information
  implements :service
  generic_name :OfficeRnD
  descriptive_name "OfficeRnD REST API"

  keepalive false

  default_settings({
    client_id:     "10000000",
    client_secret: "c5a6adc6-UUID-46e8-b72d-91395bce9565",
    scopes:        ["officernd.api.read", "officernd.api.write"],
    organization: "org-slug"
  })

  def on_load
    on_update
  end

  def on_update
    @resource_name_cache = {}

    @client_id = setting(:client_id)
    @client_secret = setting(:client_secret)
    @scopes = setting(:scopes)
    @organization = setting(:organization)

    @auth_token ||= ""
    @auth_expiry ||= 1.minute.ago

    # cache
    @timezone_cache ||= [3.days.ago, []]
    @member_cache ||= {}
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    @auth_expiry < Time.now
  end

  def get_token
    return @auth_token unless token_expired?

    client = ::UV::HttpEndpoint.new("https://identity.officernd.com")
    promise = client.post(path: "/oauth/token", body: {
      "client_id"     => @client_id,
      "client_secret" => @client_secret,
      "grant_type"    => "client_credentials",
      "scope"         => @scopes.join(' '),
    }.map { |k, v| encode_param(k, v) }.join('&'), headers: {
      "Content-Type" => "application/x-www-form-urlencoded",
      "Accept"       => "application/json",
    }).then { |response|
      body = response.body
      logger.debug { "received login response: #{body}" }

      if (200..299).include? response.status
        resp = JSON.parse(body, symbolize_names: true)
        @auth_expiry = Time.now + (resp[:expires_in] - 5)
        @auth_token = "Bearer #{resp[:access_token]}"
      else
        logger.error "authentication failed with HTTP #{response.status}"
        raise "failed to obtain access token"
      end
    }
    promise.catch { |error|
      logger.debug { "error response: #{error.inspect}" }
    }
    promise.value
  end

  def get_request(path, query = nil, url_base: "/api/v1/organizations/#{@organization}")
    token = get_token
    response = get("#{url_base}#{path}", headers: {
      "Accept" => "application/json",
      "Authorization" => token
    }, query: query) { |response|
      if (200..299).include? response.status
        JSON.parse(response.body, symbolize_names: true)
      else
        expire_token! if response.status == 401
        raise "unexpected response #{response.status}\n#{response.body}"
      end
    }.value
  end

  # Floor
  ###########################################################################

  # Get a floor
  #
  def floor(floor_id)
    get_request("/floors/#{floor_id}")
  end

  # Get floors
  #
  def floors(office_id = nil, name = nil)
    params = {}
    params["office"] = office_id if office_id
    params["name"] = name if name
    params = nil if params.empty?
    get_request("/floors", params)
  end

  # Booking
  ###########################################################################

  # Get bookings for a resource for a given time span
  #
  def resource_bookings(
    resource_id = nil,
    range_start = nil,
    range_end = nil,
    office_id = nil,
    member_id = nil,
    team_id = nil,
    rebuild_cache: false
  )
    # Use the cache
    if range_start.nil? && range_end.nil? && office_id.nil? && member_id.nil? && team_id.nil?
      cached_time, data = @timezone_cache

      if !rebuild_cache && cached_time >= 23.minutes.ago
        return data unless resource_id
        return data.select do |booking|
          booking[:resourceId] == resource_id
        end
      else
        rebuild_cache = true
      end

      range_start = 20.minutes.ago.utc
      range_end = Time.now.utc.tomorrow.tomorrow.midnight
    else
      rebuild_cache = false
    end

    params = {}
    params["office"] = office_id if office_id
    params["member"] = member_id if member_id
    params["team"] = team_id if team_id

    params["start"] = range_start.iso8601 if range_start.is_a?(Time)
    params["end"] = range_end.iso8601 if range_end.is_a?(Time)
    params["start"] = range_start.iso8601 if range_start.is_a?(String)
    params["end"] = range_end.iso8601 if range_end.is_a?(String)
    params["start"] = Time.at(range_start).iso8601 if range_start.is_a?(Integer)
    params["end"] = Time.at(range_end).iso8601 if range_end.is_a?(Integer)

    params = nil if params.empty?
    all_bookings = get_request("/bookings/occurrences", params)
    @timezone_cache = [range_start, all_bookings]
    return all_bookings unless resource_id
    all_bookings.select do |booking|
      booking[:resourceId] == resource_id
    end
  end

  def resource_free(
    resource_id,
    range_start = Time.now - 5.minutes.to_i,
    range_end = Time.now + 24.hours.to_i
  )
    resource_name = @resource_name_cache[resource_id] || resource(resource_id)[:name]
    @resource_name_cache[resource_id] = resource_name
    resources(
      nil,
      nil,
      range_start,
      range_end,
      name: resource_name
    )
  end

  # Get a booking
  #
  def booking(booking_id)
    get_request("/bookings/#{booking_id}")
  end

  # Get bookings
  #
  def bookings(
    office_id = nil,
    member_id = nil,
    team_id = nil
  )
    params = {}
    params["office"] = office_id if office_id
    params["member"] = member_id if member_id
    params["team"] = team_id if team_id
    params = nil if params.empty?
    get_request("/bookings", params)
  end

  # Delete a booking
  #
  def delete_booking(booking_id)
    !!(delete_request("/bookings/#{booking_id}"))
  end

  # Make a booking
  #
  def create_bookings(bookings)
    response = post("/bookings", body: bookings.to_json, headers: {
      "Content-Type"  => "application/json",
      "Accept"        => "application/json",
      "Authorization" => get_token,
    })
    unless (200..299).include?(response.status)
      expire_token! if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end

  # Create a booking
  #
  def create_booking(
    resource_id, # String
    booking_start, # Time
    booking_end, # Time
    summary = nil,
    team_id = nil,
    member_id = nil,
    description = nil,
    tentative = nil, # Bool
    free = nil # Bool
  )
    create_bookings [{
      resource_id: resource_id,
      start: {dateTime: booking_start},
      end: {dateTime: booking_end},
      summary: summary,
      team: team_id,
      member: member_id,
      description: description,
      tentative: tentative,
      free: free
    }]
  end

  # Retrieve member details
  #
  def staff_details(member_id, fresh: false)
    member_id = member_id.to_s
    cached = @member_cache[member_id]
    return cached if cached && !fresh

    path = "/members/#{member_id}"
    result = get_request(path)
    @member_cache[member_id] = result
  end

  # Organisation
  ###########################################################################

  # List organisations
  #
  def organisations
    path = "/organizations"
    get_request(path, url_base: "/api/v1")
  end

  # Retrieve organisation
  #
  def organisation(org_slug)
    path = "/organizations/#{org_slug}"
    get_request(path, url_base: "/api/v1")
  end

  # Office
  ###########################################################################

  # List offices
  #
  def offices
    path = "/offices"
    get_request(path)
  end

  # Retrieve office
  #
  def office(office_id)
    path = "/offices/#{office_id}"
    get_request(path)
  end

  # Resource
  ###########################################################################

  RESOURCE_TYPES = {
    "MeetingRoom" => "meeting_room",
    "PrivateOffices" => "team_room",
    "PrivateOfficeDesk" => "desk_tr",
    "DedicatedDesks" => "desk",
    "HotDesks" => "hotdesk"
  }

  def resource(resource_id)
    get_request("/resources/#{resource_id}")
  end

  # Get available rooms (resources) by
  # - type
  # - date range (available_from, available_to)
  # - office (office_id)
  # - resource name (name)
  def resources(
    type = nil,
    office_id = nil,
    available_from = nil, # Time
    available_to = nil,
    name: nil
  )
    type = (RESOURCE_TYPES[type] || type) if type
    params = {}
    params["type"] = type.to_s if type
    params["name"] = name if name
    params["office"] = office_id if office_id

    params["availableFrom"] = available_from.iso8601 if available_from.is_a?(Time)
    params["availableTo"] = available_to.iso8601 if available_to.is_a?(Time)
    params["availableFrom"] = available_from.iso8601 if available_from.is_a?(String)
    params["availableTo"] = available_to.iso8601 if available_to.is_a?(String)
    params["availableFrom"] = Time.at(available_from).iso8601 if available_from.is_a?(Integer)
    params["availableTo"] = Time.at(available_to).iso8601 if available_to.is_a?(Integer)
    params = nil if params.empty?
    get_request("/resources", params)
  end

  def meeting_rooms(
    available_from = nil, # Time
    available_to = nil,
    office_id: nil
  )
    resources("MeetingRoom", office_id, available_from, available_to)
  end

  def desks(
    available_from = nil, # Time
    available_to = nil,
    office_id: nil
  )
    resources("HotDesks", office_id, available_from, available_to)
  end

  protected

  def escape(s)
    s.to_s.gsub(/([^a-zA-Z0-9_.-]+)/) {
      '%'+$1.unpack('H2'*$1.bytesize).join('%').upcase
    }
  end

  def encode_param(k, v)
    escape(k) + "=" + escape(v)
  end
end
