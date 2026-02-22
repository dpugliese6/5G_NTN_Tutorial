# 5G_NTN_Tutorial

This is a collection of useful files and scripts for setting up a Non-Terrestrial Network (NTN) using OpenAirInterface (OAI), Software-Defined Radios (SDRs). The repository contains all the necessary utilities to set up a complete end-to-end 5G NTN with Geostationary Orbit (GEO) satellite and Low Earth Orbit (LEO) satellite.

## Overview

This repository provides an automated and modular environment to deploy a 5G NTN architecture. It relies on the Open5GS for implementing a 5G Standalone (SA) Core Network and OpenAirInterface 5G for the gNB (base station) and a UE (User Equipment). 
### Key Components

*   **5G Core Network**: Found in the `Open5GS_CN` directory, it contains a docker-compose to run a complete 5G Core Network.
*   **OAI gNB & UE**: Containerized using Docker (`docker-compose.yaml`). In case of a Regenerative satellite, it is possible to emulate the delay between the gNodeB and the Core Network (configured dynamically during startup).
*   **Dynamic Configuration Scripts**: The scripts `configure_gnb.sh` and `configure_ue.sh` are interactive. They parse modular JSON configuration files from the `confs/` directory to generate the final configuration files for the gNB and UE respectively, preventing syntax errors in the complex OAI parameters.
    *   **Configuration Layout (`confs/`)**: Contains modular pieces of configuration (`RUs`, `gNB/NTN`, etc.).

## Directory Structure

The repository is organized into specific directories to isolate different components of the 5G NTN stack:

*   **`Open5GS_CN/`**: This directory contains the Docker configuration and necessary parameters to deploy the Open5GS Core Network, acting as the backbone for the Standalone 5G architecture.
*   **`confs/`**: This folder acts as a configuration hub. It is further divided into:
    *   **`RUs/`**: Contains the configuration for different Radio Units (e.g., SDR models).
    *   **`gNB/`**: Houses gNodeB-specific configurations, including Non-Terrestrial Network (NTN) parameters like orbit delays, and base station cell parameters.
    *   **`UE/`**: Holds configurations specific to the User Equipment, along with support for additional execution flags.
*   **`configure_gnb.sh` & `configure_ue.sh`**: At the root of the project, these interactive bash scripts are used to dynamically read the JSON templates in `confs/` and generate the final configuration files required by the OpenAirInterface executables.
*   **`docker-compose.yaml`**: The main orchestration file that spins up both the gNB and UE containers based on the generated configurations, applying the simulated network delays over the virtual interfaces.

## Pre-Configuration (Network Interfaces)

Before deploying the containers, **you must configure the physical network interfaces** used by the gNodeB. The OAI gNB container uses Docker `macvlan` networks to directly access the host's physical network adapters. 

> [!NOTE]
> This configuration is **only required if you are using Network-attached SDRs** (like the USRP X310 or X410). If you are using a USB-connected SDR (such as the USRP B210), you can safely skip this step as USB devices are passed directly through Docker volumes.

1.  **Configure Macvlan Parents (Global)**: Open `docker-compose.yaml` and locate the `networks:` section at the bottom of the file. Change the `parent` interface names to match your host machine's actual network interfaces (e.g., `eth0`, `enp3s0`). You can list them using `ip a`.
    ```yaml
      macvlan0: 
        driver_opts:
          parent: enp1s0f0np0  <-- CHANGE THIS
    ```

2.  **Assign Networks to gNB Container**: Inside `docker-compose.yaml`, locate the `oai-gnb:` service block and find its `networks:` section. Here, you map the global macvlans to the container and assign static IPs that belong to the subnet of your SDRs (e.g., if the static IP of the SDR is 192.168.30.2/24, then the static IP of the adapter should be 192.168.30.x/24):
    ```yaml
      oai-gnb:
        ...
        networks:
          default:
            ipv4_address: 172.22.0.25      # Internal Core Network IP
          macvlan0:
            ipv4_address: 192.168.30.1     # IP assigned from the physical interface
          macvlan1:
            ipv4_address: 192.168.31.2
    ```

3.  **Verify Service Command Subnet**: Under the same `oai-gnb` service definition, there is a startup `command:` that looks for the virtual interface assigned by Docker (*usually the `default` network*) to apply the artificial delay:
    ```bash
    IFACE=$$(ip -o addr show | awk '/172\.22\.0\./ {print $$2; exit}');
    ```
    If you modified the default Docker subnet (`172.22.0.x`) elsewhere in your Open5GS setup, you must update this `awk` pattern to match the new IP range so the `tc netem` delay applies correctly.

## Configuration Management

Working directly with OpenAirInterface's monolithic `.conf` files can be prone to syntax errors and complex to maintain. To solve this, this repository uses a modular, template-based approach to configuration:

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
3.  **The Mapping Process**: When you execute `configure_gnb.sh` or `configure_ue.sh`, the scripts prompt you to choose these JSON profiles. They use `jq` to parse the keys and values from the selected JSON files and use regular expressions to dynamically search for and overwrite the corresponding variables inside the target `gnb_template.conf` or `ue_template.conf`. 

## Getting Started

### Dependencies

*   [UHD](https://files.ettus.com/manual/html/uhd_quickstart.html)
*   [Docker & Docker Compose](https://docs.docker.com/engine/install/)
*   [jq](https://jqlang.github.io/jq/) (used by configuration scripts)

### Setup

1.  **Core Network**: Deploy the Open5GS core network from the `Open5GS_CN` directory.
    ```bash
    cd Open5GS_CN
    docker-compose up -d
    cd ..
    ```
    
2.  **Configuration**: Generate the configuration files for your specific scenario or use some of the pre-configured examples.
    *   Construct the gNB configuration. You will be prompted to also set the network delay at this step:
        ```bash
        ./configure_gnb.sh
        ```
    *   Construct the UE configuration:
        ```bash
        ./configure_ue.sh
        ```
3.  **Launch OAI**: Spin up the OAI gNB and UE containers based on your generated configurations. You can either answer "yes" at the end of the configuration scripts, or manually run:
    ```bash
    docker compose up oai-gnb
    ```
    and in a separate terminal:
    ```bash
    docker compose up oai-nr-ue
    ```

