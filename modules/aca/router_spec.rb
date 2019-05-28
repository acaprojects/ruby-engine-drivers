# frozen_string_literal: true

require 'json'

Orchestrator::Testing.mock_device 'Aca::Router' do
    def section(message)
        puts "\n\n#{'-' * 80}"
        puts message
        puts "\n"
    end

    SignalGraph = Aca::Router::SignalGraph

    # -------------------------------------------------------------------------
    section 'Internal graph structure'

    graph = SignalGraph.new

    # Node insertion
    graph << :test_node
    expect(graph).to include(:test_node)

    # Node access
    expect(graph[:test_node]).to be_a(SignalGraph::Node)
    expect { graph[:does_not_exist] }.to raise_error(ArgumentError)

    # Node deletion
    graph.delete :test_node
    expect(graph).not_to include(:test_node)

    # Edge creation
    graph << :display
    graph << :laptop
    graph.join(:display, :laptop) do |edge|
        edge.device = :Display_1
        edge.input  = :hdmi
    end
    expect(graph.successors(:display)).to include(:laptop)

    # Graph structural inspection
    # note: signal flow is inverted from graph directivity
    expect(graph.indegree(:display)).to be(0)
    expect(graph.indegree(:laptop)).to be(1)
    expect(graph.outdegree(:display)).to be(1)
    expect(graph.outdegree(:laptop)).to be(0)
    expect(graph.sources).to include(:display)
    expect(graph.sinks).to include(:laptop)

    # Edge inspection
    edge = graph[:display].edges[:laptop]
    expect(edge.device).to be(:Display_1)
    expect(edge.input).to be(:hdmi)
    expect(edge).to be_nx1
    expect(edge).not_to be_nxn


    # -------------------------------------------------------------------------
    section 'Parse from signal map'

    signal_map = JSON.parse <<-JSON
        {
            "Display_1 as Left_LCD": {
                "hdmi": "Switcher_1__1",
                "hdmi2": "SubSwitchA__1",
                "hdmi3": "Receiver_1"
            },
            "Display_2 as Right_LCD": {
                "hdmi": "Switcher_1__2",
                "hdmi2": "SubSwitchB__2",
                "display_port": "g"
            },
            "Switcher_1": ["a", "b"],
            "Switcher_2 as SubSwitchA": {
                "1": "c",
                "2": "d"
            },
            "Switcher_2 as SubSwitchB": {
                "3": "e",
                "4": "f"
            },
            "Receiver_1": {
                "hdbaset": "Transmitter_1"
            },
            "Transmitter_1": {
                "hdmi": "h"
            }
        }
    JSON

    normalised_map = SignalGraph.normalise(signal_map)
    expect(normalised_map).to eq(
        'Display_1 as Left_LCD' => {
            hdmi: 'Switcher_1__1',
            hdmi2: 'SubSwitchA__1',
            hdmi3: 'Receiver_1'
        },
        'Display_2 as Right_LCD' => {
            hdmi: 'Switcher_1__2',
            hdmi2: 'SubSwitchB__2',
            display_port: 'g'
        },
        'Switcher_1' => {
            1 => 'a',
            2 => 'b'
        },
        'Switcher_2 as SubSwitchA' => {
            1 => 'c',
            2 => 'd'
        },
        'Switcher_2 as SubSwitchB' => {
            3 => 'e',
            4 => 'f'
        },
        'Receiver_1' => {
            hdbaset: 'Transmitter_1'
        },
        'Transmitter_1' => {
            hdmi: 'h'
        }
    )

    mods = SignalGraph.extract_mods!(normalised_map)
    expect(mods).to eq(
        'Left_LCD'      => 'Display_1',
        'Right_LCD'     => 'Display_2',
        'Switcher_1'    => 'Switcher_1',
        'SubSwitchA'    => 'Switcher_2',
        'SubSwitchB'    => 'Switcher_2',
        'Receiver_1'    => 'Receiver_1',
        'Transmitter_1' => 'Transmitter_1'
    )
    expect(normalised_map).to eq(
        Left_LCD: {
            hdmi: 'Switcher_1__1',
            hdmi2: 'SubSwitchA__1',
            hdmi3: 'Receiver_1'
        },
        Right_LCD: {
            hdmi: 'Switcher_1__2',
            hdmi2: 'SubSwitchB__2',
            display_port: 'g'
        },
        Switcher_1: {
            1 => 'a',
            2 => 'b'
        },
        SubSwitchA: {
            1 => 'c',
            2 => 'd'
        },
        SubSwitchB: {
            3 => 'e',
            4 => 'f'
        },
        Receiver_1: {
            hdbaset: 'Transmitter_1'
        },
        Transmitter_1: {
            hdmi: 'h'
        }
    )

    graph = SignalGraph.from_map(signal_map)

    expect(graph.sources).to contain_exactly(:Left_LCD, :Right_LCD)

    expect(graph.sinks).to contain_exactly(*(:a..:h).to_a)

    routes = graph.sources.map { |id| [id, graph.dijkstra(id)] }.to_h
    expect(routes[:Left_LCD].distance_to[:a]).to be(2)
    expect(routes[:Left_LCD].distance_to[:c]).to be(2)
    expect(routes[:Left_LCD].distance_to[:e]).to be_infinite
    expect(routes[:Left_LCD].distance_to[:g]).to be_infinite
    expect(routes[:Right_LCD].distance_to[:g]).to be(1)
    expect(routes[:Right_LCD].distance_to[:a]).to be(2)
    expect(routes[:Right_LCD].distance_to[:g]).to be(1)
    expect(routes[:Right_LCD].distance_to[:c]).to be_infinite


    # -------------------------------------------------------------------------

    exec(:load_from_map, signal_map)

    # -------------------------------------------------------------------------
    section 'Routing'

    exec(:route, :a, :Left_LCD)
    nodes, edges = result
    expect(nodes).to contain_exactly(:a, :Switcher_1__1, :Left_LCD)
    expect(edges.first).to be_nxn
    expect(edges.first.device).to be(:Switcher_1)
    expect(edges.first.input).to be(1)
    expect(edges.first.output).to be(1)
    expect(edges.second).to be_nx1
    expect(edges.second.device).to be(:Display_1)
    expect(edges.second.input).to be(:hdmi)

    exec(:route, :c, :Left_LCD)
    nodes, = result
    expect(nodes).to contain_exactly(:c, :SubSwitchA__1, :Left_LCD)

    expect { exec(:route, :e, :Left_LCD) }.to \
        raise_error('no route from e to Left_LCD')

    # -------------------------------------------------------------------------
    section 'Edge maps'

    exec(:build_edge_map, a: :Left_LCD, b: :Right_LCD)
    edge_map = result
    expect(edge_map.keys).to contain_exactly(:a, :b)
    expect(edge_map[:a]).to be_a(Hash)
    expect(edge_map[:a][:Left_LCD]).to be_a(Array)


    # -------------------------------------------------------------------------
    section 'Graph queries'

    exec(:input_for, :a)
    expect(result).to be(1)

    exec(:input_for, :a, on: :Left_LCD)
    expect(result).to be(:hdmi)

    exec(:device_for, :g)
    expect(result).to be(:Display_2)

    exec(:devices_between, :c, :Left_LCD)
    expect(result).to contain_exactly(:Switcher_2, :Display_1)

    exec(:upstream_devices_of, :Left_LCD, on_input: :hdmi3)
    expect(result).to contain_exactly(:Receiver_1, :Transmitter_1, :h)

    exec(:upstream_devices_of, :Left_LCD)
    expect(result).to be_empty
end
