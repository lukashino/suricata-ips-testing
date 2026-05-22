# Suricata IPS Test Lab (Virtual)

This repo contains a command-line helper to aid in testing Suricata IPS
modes, with a particular attention on the developer. Automated
strategies are currently not in scope.

The main entry point is `ips-lab`. Install it as a symlink somewhere in
your `PATH` with:

```
./install.sh
```

The installer prompts for `~/.local/bin`, `/usr/local/bin`, or a custom
location. Because `ips-lab` is installed as a symlink, updates are
picked up by running `git pull` in this checkout.

The following scenarios are supported:

* NFQ IPS, routed.
* AF_PACKET IPS, bridged.

## Requirements

* Linux: `ips-lab` makes use of Linux network name spaces to provide
  the virtual lab environment.

## Commands

```
ips-lab up [afp|nfq] [--queue-bypass]
ips-lab down
ips-lab status
ips-lab enter [dut|client|server]
ips-lab setup linux-bridge [up|down]
```

`afp` is the default mode for `ips-lab up`. The `server` entry point is
the root namespace side of the lab.

## NFQ IPS

To create a NFQ IPS test environment:

```
ips-lab up nfq
```

This will create 2 name spaces environments:

* DUT: The device under test, this is where you'll run Suricata.
* Client: The device that is protected by the DUT.

To enter the DUT:

```
ips-lab enter dut
```

To enter the client:

```
ips-lab enter client
```

Notes:

* In both environments you will have access to your full file
  system. These are no sandboxes or containers.
* As the DUT is acting as a Linux NAT'ing firewall, it does have
  internet access.
* The client will **NOT** have internet until Suricata is started in
  NFQ inline mode.
* If you need the client to have internet access without Suricata
  running, you can add the `--queue-bypass` option when bringing the
  lab environment up: `ips-lab up nfq --queue-bypass`.

## AF_PACKET IPS

To create an AF_PACKET IPS test environment:

```
ips-lab up afp
```

This will create 2 name spaces environments:

* DUT: The device under test, this is where you'll run Suricata.
* Client: The device that is protected by the DUT.

To enter the DUT:

```
ips-lab enter dut
```

To enter the client:

```
ips-lab enter client
```

Notes:

* In both environments you will have access to your full file
  system. These are no sandboxes or containers.
* The DUT does not have internet access itself, there is no management
  interface like you might have in a real world deployment.
* The client will **NOT** have internet until Suricata is started in
  AF_PACKET inline mode.
* If you need internet access in the client without running Suricata,
  you can enable Linux bridging with the following command run
  **INSIDE** the DUT:

    ```
    ips-lab setup linux-bridge
    ```

  And to disable the Linux bridge:

    ```
    ips-lab setup linux-bridge down
    ```

  Be careful not run Suricata and the Linux bridge at the same
  time. Nothing will break, you just won't be testing what you think
  you are testing.

## Credits

Thanks to Victor Julien for adding the Linux name space tests to our
CI, which this lab helper is based off.
