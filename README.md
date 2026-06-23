# 5G_NTN_Tutorial

This is a collection of useful files and scripts for setting up a Non-Terrestrial Network (NTN) using OpenAirInterface (OAI) and Software-Defined Radios (SDRs). The repository contains all the necessary utilities to set up a complete end-to-end 5G NTN with Geostationary Orbit (GEO) satellite and Low Earth Orbit (LEO) satellite.

## Overview

This repository provides an automated and modular environment to deploy a 5G NTN architecture. It relies on Open5GS for implementing a 5G Standalone (SA) Core Network and OpenAirInterface5G for the gNB and a UE. 
### Key Components

*   **5G Core Network**: The Open5GS Core Network is launched via `docker-compose_cn.yaml`, while the `cn/` directory holds the per-NF configuration files (AMF, SMF, UPF, etc.).
*   **Custom OAI (`oai-custom`)**: A fork of OpenAirInterface5G included as a **git submodule** ([duranta-project/openairinterface5g](https://github.com/duranta-project/openairinterface5g.git)). It must be compiled on the host **before** building the RAN images (see [Build the Custom OAI](#1-build-the-custom-oai)), since the Docker images copy the pre-built binaries.
*   **OAI gNB & UE**: Containerized using Docker (`docker-compose_ran.yaml`). The compose file defines both the official upstream images (`oai-gnb`, `oai-nr-ue`) and the custom ones built locally from `oai-custom` (`gnb-cst` via `Dockerfile_gnb`, `ue-cst` via `Dockerfile_ue`). In case of a Regenerative satellite, it is possible to emulate the delay between the gNodeB and the Core Network (configured dynamically during startup).
*   **Dynamic Configuration Scripts**: The scripts `configure_gnb.sh` and `configure_ue.sh` are interactive. They parse modular JSON configuration files from the `confs/` directory to generate the final configuration files for the gNB and UE respectively, preventing syntax errors in the complex OAI parameters.
    *   **Configuration Layout (`confs/`)**: Contains modular pieces of configuration (`RUs`, `gNB/NTN`, etc.).
*   **Measurement Scripts (`propsim_control/`)**: A collection of helper scripts to drive the propagation-channel emulator and run test campaigns (attach tests, RTT, downlink/uplink throughput).

## Pre-Configuration (Network Interfaces)

Before deploying the containers, **you must configure the physical network interfaces** used by the gNB. The OAI gNB container uses Docker `macvlan` networks to directly access the host's physical network adapters. 

> [!NOTE]
> This configuration is **only required if you are using Network-attached SDRs** (like the USRP X310 or X410). If you are using a USB-connected SDR (such as the USRP B210), you can safely skip this step as USB devices are passed directly through Docker volumes.

1.  **Configure Macvlan Parents (Global)**: Open `docker-compose_ran.yaml` and locate the `networks:` section at the bottom of the file. Change the `parent` interface names of `macvlan0`/`macvlan1`/`macvlan2` to match your host machine's actual network interfaces (e.g., `eth0`, `enp3s0`). You can list them using `ip a`.
    ```yaml
      macvlan0: 
        driver_opts:
          parent: enp1s0f0np0  <-- CHANGE THIS
    ```

2.  **Assign Networks to gNB Container**: Inside `docker-compose_ran.yaml`, locate the gNB service block (`oai-gnb:` for the official image, or `gnb-cst:` for the custom build) and find its `networks:` section. Here, you map the global macvlans to the container and assign static IPs that belong to the subnet of your SDRs (e.g., if the static IP of the SDR is 192.168.30.2/24, then the static IP of the adapter should be 192.168.30.x/24):
    ```yaml
      oai-gnb:
        ...
        networks:
          default:
            ipv4_address: 172.22.0.25      # Inside CN IP
          macvlan0:
            ipv4_address: 192.168.30.1     # IP of to the net if
          macvlan1:
            ipv4_address: 192.168.31.1
          macvlan2:
            ipv4_address: 192.168.40.1
    ```

3.  **Verify Service Command Subnet**: Under the same `oai-gnb` service definition, there is a startup `command:` that looks for the virtual interface assigned by Docker (*usually the `default` network*) to apply the artificial delay:
    ```bash
    IFACE=$$(ip -o addr show | awk '/172\.22\.0\./ {print $$2; exit}');
    ```
    If you modified the default Docker subnet (`172.22.0.x`) elsewhere in your Open5GS setup, you must update this `awk` pattern to match the new IP range so the `tc netem` delay applies correctly.

## Configuration Management

Working directly with OpenAirInterface's monolithic `.conf` files can be prone to syntax errors and complex to maintain. To solve this, the repository uses a modular, template-based approach to configuration:

1.  **OAI Templates**: Inside the `confs/` folder, there are two primary files (`gnb_template.conf` and `ue_template.conf`). These are standard OAI configuration files that act as the base blueprints. They contain placeholders and default values for all parameters.
2.  **JSON Modules**: Instead of modifying the monolithic blueprints directly, configurations are logically grouped into smaller, manageable `.json` files. These modules fall into three main categories:
    *   **Radio Units (`confs/RUs/`)**: Defines hardware-specific parameters like IP/Serial, Attenuation, and RxGain.
        ```json
        {
         "att_tx"    : 0,
         "att_rx"    : 19,
         "max_rxgain": 120,
         "sdr_addrs" : "serial = 31C5255"
        }
        ```
    *   **gNodeB / NTN (`confs/gNB/`)**: Contains parameters for the cell and orbit configurations like HARQ modes, ephemeris data (position/velocity), and K-offsets.
        ```json
        {
          "disable_harq": 1,
          "ntn-UlSyncValidityDuration-r17": 0,
          "cellSpecificKoffset_r17": 240,
          "ta-Common-r17": 0,
          "ta-CommonDrift-r17": 0,
          "positionX-r17": 32433951,
          "positionY-r17": 0,
          "positionZ-r17": 0,
          "velocityVX-r17": 0,
          "velocityVY-r17": 0,
          "velocityVZ-r17": 0,
          "dl_max_mcs": 28,
          "ul_max_mcs": 28
        }
        ```
    *   **UE Flags (`confs/UE/UE_additional_flags/`)**: Unlike the other JSONs, these key-value pairs are translated directly into command-line arguments (like `--initial-fo`) instead of being written inside the `.conf` file.
        ```json
        {
         "--ntn-initial-time-drift" : -16,
         "--ue-fo-compensation" : true,
         "--initial-fo" : 25250, 
         "--cont-fo-comp" : 2,
         "--num-ul-actors" : 1, 
         "--time-sync-I" : 0.1, 
         "--autonomous-ta" : true
        }
        ```
3.  **The Mapping Process**: When you execute `configure_gnb.sh` or `configure_ue.sh`, the scripts prompt you to choose these JSON profiles.  

## Getting Started

### Dependencies

*   [UHD](https://files.ettus.com/manual/html/uhd_quickstart.html)
*   [Docker & Docker Compose](https://docs.docker.com/engine/install/)
*   [jq](https://jqlang.github.io/jq/) (used by configuration scripts)

### Setup

#### 1. Build the Custom OAI

The custom OAI fork is included as a git submodule (`oai-custom`) and **must be compiled on the host before building the RAN images**, because `Dockerfile_gnb` / `Dockerfile_ue` copy the binaries produced under `oai-custom/cmake_targets/ran_build/build/`.

*   Initialize (and update) the submodule:
    ```bash
    git submodule update --init
    ```
*   Compile the gNB, UE and the USRP support from the submodule:
    ```bash
    cd oai-custom/cmake_targets
    ./build_oai --ninja \
          --gNB --nrUE \
          --build-lib "nrscope" -w USRP \
          --cmake-opt -DCMAKE_C_FLAGS="-Werror" --cmake-opt -DCMAKE_CXX_FLAGS="-Werror"
    cd ../..
    ```

#### 2. Core Network

Deploy the Open5GS core network:
```bash
docker compose -f docker-compose_cn.yaml up -d
```

#### 3. Configuration

Generate the configuration files for your specific scenario or use some of the pre-configured examples.
*   Construct the gNB configuration. You will be prompted to also set the network delay at this step:
    ```bash
    ./configure_gnb.sh
    ```
*   Construct the UE configuration:
    ```bash
    ./configure_ue.sh
    ```

#### 4. Launch OAI

Spin up the gNB and UE containers based on your generated configurations. You can either answer "yes" at the end of the configuration scripts, or manually run them. Use the custom-built services (`gnb-cst` / `ue-cst`, built from `oai-custom`):
```bash
docker compose -f docker-compose_ran.yaml up gnb-cst
```
```bash
docker compose -f docker-compose_ran.yaml up ue-cst
```
Alternatively, the official upstream images are available as the `oai-gnb` and `oai-nr-ue` services in the same compose file.

## Configuration Parameters Reference

This section details the most important parameters you can configure across the different JSON modules.

### 1. Radio Units (RUs)

The files in `confs/RUs/` define the physical connection and RF front-end settings for the Software-Defined Radios (SDRs). These configurations are shared between both gNB and UE setups, with minor differences depending on the hardware model (e.g., USRP B210 vs. USRP X310/X410).

*   `sdr_addrs`: The address used by the UHD driver to find the SDR, you can find this value by running the `uhd_find_devices` command. 
    *   For USB-connected SDRs (like the B210), this is usually the serial number: `"serial = 31C5255"`.
    *   For Network-attached SDRs (like X310 or X410), this is the static IP address: `"addr = 192.168.30.2"`.
*   `att_tx` : This value is used in OAI to set the transmission gain of the SDR. The value inserted is subtracted from the maximum gain of the SDR. 
*   `att_rx`: This value is used in OAI to set the reception gain of the SDR. The value inserted is subtracted from the maximum gain of the SDR. 
*   `max_rxgain`: Set the mximum rx gain of the SDR.
*   `time_src` / `clock_src`: Usually set to `"external"` if relying on an external GPSDO/10MHz reference clock to maintain tight synchronization.
*   `tx_subdev` / `rx_subdev`: Selects which specific RF daughterboard and antenna port to use.


### 2. Cells

This section defines the basic parameters of the 5G New Radio (NR) cell being broadcasted, but the configurations differ depending on whether you are setting up the base station or the user equipment.

#### gNB Cell Parameters (`confs/gNB/Cells/`)
*   `absoluteFrequencySSB` / `dl_absoluteFrequencyPointA`: Defines the exact center frequency and starting point of the carrier in Hz.
*   `dl_carrierBandwidth` / `ul_carrierBandwidth`: The width of the carrier expressed in Physical Resource Blocks (PRBs) (e.g., `106` PRBs represents a 20MHz bandwidth with SCS of 15 kHz).
*   `dl_frequencyBand` / `ul_frequencyBand`: The 3GPP Band number being operated on (e.g., Band `255` for Non-Terrestrial L-band).
*   `dl_subcarrierSpacing` / `ul_subcarrierSpacing`: The numerology (SCS) of the cell. Typically `1` (30kHz) or `0` (15kHz).
*   `initialDLBWPlocationAndBandwidth` / `initialULBWPlocationAndBandwidth`: Defines the frequency domain location and bandwidth of the initial Bandwidth Part (BWP) for Downlink and Uplink.

#### UE Cell Parameters (`confs/UE/Cells/`)
This parameters can be found in the gNB logs after the gNB is started. The logs will show the following message: 

```bash
oai-gnb | [PHY]  Command line parameters for OAI UE: -C 1549000000 --CO 101500000 -r 106 --numerology 0 --ssb 226
```

*   `band`: The 3GPP Band number the UE should tune to (e.g., `255`).
*   `rf_freq`: The base radio frequency (in Hz) the UE will listen to for the downlink carrier (in the gNB command line logs is -C).
*   `rf_offset`: The duplex spacing between the Downlink and Uplink frequencies (in Hz). Used to calculate the transmit frequency (in the gNB command line logs is --CO).
*   `numerology`: The Subcarrier Spacing (SCS) index (e.g., `0` for 15kHz, in the gNB command line logs is --numerology).
*   `N_RB_DL`: The Downlink Bandwidth expressed in Physical Resource Blocks (PRBs), corresponds to -r.
*   `ssb_start`: The subcarrier offset where the Synchronization Signal Block (SSB) starts. Essential for the UE to properly lock onto the gNB's beacon, is --ssb.

### 3. Non-Terrestrial Networks (NTN)

The files in `confs/gNB/NTN/` contain configurations that adapt standard 5G cells into NTN cells. They handle the orbital mechanics and massive propagation delays introduced by satellite communications. For more details on the NTN parameters, please refer to the the openairinterface NTN documentation [RUNMODEM.md](https://gitlab.eurecom.fr/oai/openairinterface5g/-/blob/develop/doc/RUNMODEM.md?ref_type=heads).

*   `disable_harq`: NTN links (especially GEO) have RTTs much larger than standard 5G HARQ timers can handle. This variable often gets set to `1` to disable the HARQ feedback loop entirely, relying strictly on RLC-AM or upper layers for reliability.
*   `ntn-UlSyncValidityDuration-r17`: Defines the maximum duration (in seconds) during which the UE can safely apply orbital assistance information before requiring an update (e.g., re-reading SIB19). Typical values are `240`s for GEO, `20`s for MEO, and `5`s for LEO.
*   `cellSpecificKoffset_r17`: A crucial scheduling offset (defined in TS 38.213) used to shift the standard downlink-to-uplink MAC timing relationships to account for massive Round-Trip Times (RTT). The value is expressed in number of slots, specifically for a baseline 15 kHz subcarrier spacing (SCS). Should be set to the RTT between the gNB and the UE rounded up to the nearest integer.
*   `ta-Common-r17`: The baseline Timing Advance representing the propagation delay between the gNB reference point and the satellite. This value is given in units of its corresponding granularity ($4.072 \times 10^{-3}$ µs). In the a regenerative configuration is set to 0 because the gNB is located on the satellite.
*   `ta-CommonDrift-r17`: Incorporates the drift rate (rate of change) of the common Timing Advance, critical for the fast-moving LEO satellites. Given in units of corresponding granularity ($0.2 \times 10^{-3}$ µs/s).
*   `positionX-r17`, `positionY-r17`, `positionZ-r17`: The orbital Ephemeris data defining the satellite's exact position state vector in the ECEF coordinate system. Values are provided in steps of $1.3$ meters (Actual position in meters = field value $\times \ 1.3$).
*   `velocityVX-r17`, `velocityVY-r17`, `velocityVZ-r17`: The velocity state vector of the satellite in ECEF, used by the UE to perform Doppler pre-compensation. Values are provided in steps of $0.06$ m/s (Actual velocity in m/s = field value $\times \ 0.06$).
*   `dl_max_mcs` / `ul_max_mcs`: Force the scheduler to cap the Modulation and Coding Scheme (MCS) to a maximum value.