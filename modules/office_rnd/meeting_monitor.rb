# frozen_string_literal: true
# encoding: ASCII-8BIT

module OfficeRnd; end

class OfficeRnd::DeskBookingMonitor
  include ::Orchestrator::Constants

  descriptive_name 'OfficeRnD Desk Monitor'
  generic_name :DeskMonitor
  implements :logic

  def on_load
    @updates_pushed = 0
    # id => details
    @staff_details = {}

    # desk_id => "booked-by"
    @booking_state = {}
    on_update
  end

  def on_update
    @customer = (setting(:customer) || "aca")
    @source = (setting(:source) || "OfficeRnD").downcase

    sys = system
    @module_id = ::Orchestrator::System.get(sys.id).get(:DeskMonitor, 1).settings.id
    zones = ::Orchestrator::ControlSystem.find(sys.id).zone_data
    @org_id = zones.select { |zone| zone.tags.include?("org") }.first&.id
    @bld_id = zones.select { |zone| zone.tags.include?("building") }.first&.id

    schedule.clear
    schedule.every("5m") { check_bookings }
  end

  def staff_info(member_id)
    return "unknown@admin.com" unless member_id

    details  = @staff_details[member_id]
    return details if details

    officernd = system[:OfficeRnD]
    info = officernd.staff_details(member_id).value
    @staff_details[member_id] = info[:email]
    info
  end

  def check_bookings
    officernd = system[:OfficeRnD]

    officernd.resources("day_desk").then { |desks|
      logger.debug { "found #{desks.length} desks" }
      desks.select { |desk|
        # Filter manly desks
        desk[:office] == "5caada47b4621d022c8ebe1d"
      }.map { |desk|
        # Update the data
        {
          id: desk[:_id],
          name: "day_desk_#{desk[:number]}"
        }
      }
    }.then { |desks|
      # Find each desks availability
      logger.debug { "getting bookings for #{desks.length} desks" }
      promises = desks.map do |desk|
        officernd.resource_bookings(desk[:id]).then { |bookings|
          desk[:bookings] = bookings.map { |booking|
            {
              start_epoch: Time.parse(booking[:start][:dateTime]).to_i,
              end_epoch: Time.parse(booking[:end][:dateTime]).to_i,
              email: staff_info(booking[:member])
            }
          }
        }.value
      end
      # Wait for resolution - don't want to hit rate limits
      # promises.each(&:value)
      desks
    }.then do |desks|
      logger.debug { "Checking usage of #{desks.length} desks" }
      now = Time.now.to_i
      writer = system[:S3Writer]
      desks.each { |desk| check_room_usage(writer, now, desk) }
    end
  end

  protected

  def check_room_usage(writer, now, desk)
    current_booking = nil

    desk[:bookings].each do |booking|
      if now < booking[:end_epoch] && now > booking[:start_epoch]
        current_booking = booking[:email]
        break
      end
    end
    state = current_booking || false
    name = desk[:name]

    if @booking_state[name] != state
      @booking_state[name] = state
      push_changes(writer, name, !!state, state)
    end
  end

  def push_changes(writer, desk_name, in_use, owner_email)
    write_booked(writer, desk_name, @org_id, @bld_id, nil, @module_id, in_use, owner_email)
    @updates_pushed += 1
    self[:updates_pushed] = @updates_pushed
  end

  def write_booked(place, desk_name, org_id, bld_id, lvl_id, module_id, desk_in_use, owner_email)
    in_use = desk_in_use ? 1 : 0

    logger.debug do
      writing = {
        evt: "booked",
        org: org_id,
        bld: bld_id,
        lvl: lvl_id,
        loc: desk_name,
        src: @source,
        mod: module_id,
        val: in_use,
        ref: owner_email
      }
      "writing #{@customer}\n#{writing}"
    end

    place.ingest(
      @customer,
      evt: "booked",
      org: org_id,
      bld: bld_id,
      lvl: lvl_id,
      loc: desk_name,
      src: @source,
      mod: module_id,
      val: in_use,
      ref: owner_email
    )
  end
end
