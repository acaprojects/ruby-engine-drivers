require "uri"
require "securerandom"

module PointGrab; end

# Documentation: https://aca.im/driver_docs/PointGrab/CogniPointAPI2-1.pdf

class PointGrab::CogniPoint
  include ::Orchestrator::Constants
  include ::Orchestrator::Transcoder

  # Discovery Information
  implements :service
  generic_name :FloorManagement
  descriptive_name "PointGrab CogniPoint REST API"

  keepalive false

  default_settings({
    user_id: "10000000",
    app_key: "c5a6adc6-UUID-46e8-b72d-91395bce9565",
    floor_mappings: {
      "CogniPoint_floor_id" => "zone_id"
    },
    area_mappings: {
      "CogniPoint_area_id" => "alternative_area_id"
    }
  })

  def on_load
    on_update
  end

  def on_update
    @user_id = setting(:user_id)
    @app_key = setting(:app_key)

    @auth_token ||= ""
    @auth_expiry ||= 1.minute.ago

    @floor_mappings = setting(:floor_mappings)
    @area_mappings = setting(:area_mappings)

    # @floor_details["zone_id"] = {
    # "area_1": {
    #    "capacity": 100,
    #    "people_count": 90
    # }}
    @floor_details ||= {}
  end

  def expire_token!
    @auth_expiry = 1.minute.ago
  end

  def token_expired?
    @auth_expiry < Time.now
  end

  def get_token
    return @auth_token unless token_expired?

    post("/be/cp/oauth2/token", body: "grant_type=client_credentials", headers: {
      "Content-Type"  => "application/x-www-form-urlencoded",
      "Accept"        => "application/json",
      "Authorization" => [@user_id, @app_key]
    }) { |response|
      body = response.body
      logger.debug { "received login response: #{body}" }

      if response.status == 200
        resp = JSON.parse(body, symbolize_names: true)
        @auth_expiry = Time.now + (resp[:expires_in] - 5)
        @auth_token = "Bearer #{resp[:token]}"
      else
        logger.error "authentication failed with HTTP #{response.status}"
        raise "failed to obtain access token"
      end
    }.value
  end

  def get_request(path)
    token = get_token
    response = get(path, headers: {
      "Accept" => "application/json",
      "Authorization" => token
    }) { |response|
      if (200..299).include? response.status
        JSON.parse(response.body, symbolize_names: true)
      else
        expire_token! if response.status == 401
        raise "unexpected response #{response.status}\n#{response.body}"
      end
    }.value
  end

  def customers
    customers = get_request("/be/cp/v2/customers")
    # [{id: "", name: ""}]
    self[:customers] = customers[:endCustomers]
  end

  # [{id: "", name: "", customerId: "",
  # location: {houseNo: "", street: "", city: "", county: "", state: "",
  # country: "", zip: "", geoPosition: {latitude: 0.0, longitude: 0.0}}}]
  def sites
    sites = get_request("/be/cp/v2/sites")
    self[:sites] = sites[:sites]
  end

  def site(site_id)
    get_request("/be/cp/v2/sites/#{site_id}")
  end

  # [{id: "", name: "", siteId: "", location: {..}}]
  def buildings(site_id)
    buildings = get_request("/be/cp/v2/sites/#{site_id}/buildings")
    self[:buildings] = buildings[:buildings]
  end

  def building(site_id, building_id)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}")
  end

  # [{ id: "", name: "",  floorNumber: "", floorPlanURL: "", widthDistance: 0.0, lengthDistance: 0.0 }]
  def floors(site_id, building_id)
    floors = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors")
    self[:floors] = floors[:floors]
  end

  def floor(site_id, building_id, floor_id)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}")
  end

  # [{floorId: "", areas: [{id: "", name: "", length: 0.0, width: 0.0, centerX: 0.0, centerY: 0.0
  # rotation: 0, frequency: 0, deviceIDs: [""], applications: [{areaType: "", applicationType: ""}]
  # metricPositions: [{posX: 0.0, posY: 0.0}], geoPositions: [{latitude: 0.0, longitude: 0.0}] }] }]
  def building_areas(site_id, building_id)
    floors = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/areas")
    self[:floor_areas] = floors[:floorsAreas]
  end

  # as above
  def areas(site_id, building_id, floor_id)
    areas = get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}/areas")
    self[:areas] = areas[:areas]
  end

  def area(site_id, building_id, floor_id, area_id)
    get_request("/be/cp/v2/sites/#{site_id}/buildings/#{building_id}/floors/#{floor_id}/areas/#{area_id}")
  end

  # enum NotificationType
  #  Counting
  #  Traffic
  # end

  def subscribe(handler_uri, auth_token = SecureRandom.uuid, events = "Counting")
    # Ensure the handler is a valid URI
    URI.parse handler_uri

    token = get_token
    post(
      "/be/cp/v2/telemetry/subscriptions",
      body: {
        subscriptionType: "PUSH",
        notificationType: events.to_s.upcase,
        endpoint:         handler_uri,
        token:            auth_token,
      }.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "Authorization" => token,
      }
    ) { |response|
      body = response.body
      logger.debug { "received login response: #{body}" }

      if (200..299).include? response.status
        JSON.parse(body, symbolize_names: true)
      else
        logger.error "authentication failed with HTTP #{response.status}"
        raise "failed to obtain access token"
      end
    }
  end

  # [{id: "", name: "", started: false, endpoint: "", uri: "", notificationType: "", subscriptionType: ""}]
  def subscriptions
    get_request("/be/cp/v2/telemetry/subscriptions")
  end

  def delete_subscription(id)
    token = get_token
    delete("/be/cp/v2/telemetry/subscriptions/#{id}",
      headers: {
        "Accept"        => "application/json",
        "Authorization" => token,
      }
    ) { |response| (200..299).include?(response.status) ? :success : :abort }
  end

  def update_subscription(id, started = true)
    token = get_token
    patch(
      "/be/cp/v2/telemetry/subscriptions/#{id}",
      body: {started: started}.to_json,
      headers: {
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "Authorization" => token,
      }
    ) { |response| (200..299).include?(response.status) ? :success : :abort }
  end

  def get_area_details(area_id)
    return @area_details[area_id] if @area_details && @area_details[area_id]

    site_lookup = {}
    building_lookup = {}
    floor_lookup = {}
    area_details = {}

    site_ids = sites.map do |site|
      id = site[:id]
      site_lookup[id] = site[:name]
      id
    end

    site_ids.each do |site_id|
      site_name = site_lookup[site_id]

      building_ids = buildings(site_id).map do |building|
        id = building[:id]
        building_lookup[id] = building[:name]
        id
      end

      building_ids.each do |building_id|
        building_name = building_lookup[building_id]

        floors(site_id, building_id).each do |floor|
          floor_lookup[floor[:id]] = floor[:name]
        end

        building_areas(site_id, building_id).each do |floor|
          floor_id = floor[:floorId]
          floor_name = floor_lookup[floor_id]

          floor[:areas].each do |area|
            floor_area_id = area[:id]

            area_details[floor_area_id] = {
              site_id: site_id,
              site_name: site_name,
              building_id: building_id,
              building_name: building_name,
              floor_id: floor_id,
              floor_name: floor_name
            }.merge(area)
          end
        end
      end
    end

    @site_lookup = site_lookup
    @building_lookup = building_lookup
    @floor_lookup = floor_lookup
    @area_details = area_details
    self[:areas] = area_details

    @area_details[area_id]
  end

  # this data is posted to the subscription endpoint
  # we need to implement webhooks for this to work properly
  # {areaId: "", devices: [""], type: "", timestamp: 0, count: 0}
  def update_count(count_json)
    count = JSON.parse(count_json, symbolize_names: true)
    area_id = count[:areaId]
    people_count = count[:count]

    # self["zone_id"] = {
    # "area_1": {
    #    "capacity": 100,
    #    "people_count": 90
    # }}

    area_details = get_area_details(area_id)
    if area_details
      # Grab the details
      floor_id = area_details[:floor_id]
      floor_mapping = @floor_mappings[floor_id] || floor_id
      area_mapping = @area_mappings[area_id] || area_id

      # update the details
      floor_areas = @floor_details[floor_mapping] || {}
      floor_areas[area_mapping] = {
        people_count: people_count
      }
      @floor_details[floor_mapping] = floor_areas

      self[floor_mapping] = floor_areas.dup
    end
  end
end
