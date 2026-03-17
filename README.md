# Suricata IPS Test Lab (Virtual)

This repo contains scripts to aid in testing Suricata IPS modes, with
a particular attention on the developer. Automated strategies are
currently not in scope.

The following scenarios are supported:

* NFQ IPS, routed.
* AF_PACKET IPS, bridged.

## Requirements

* Linux: These scripts make use of Linux network name spaces to
  provide the virtual lab environment.

## NFQ IPS

To create a NFQ IPS test environment:

```
./ips-nfq-lab.sh up
```

This will create 2 name spaces environments:

* DUT: The device under test, this is where you'll run Suricata.
* Client: The device that is protected by the DUT.

To enter the DUT:

```
./enter-dut.sh
```

To enter the client:

```
./enter-client.sh
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
  lab environment up.

## AF_PACKET IPS

To create a NFQ IPS test environment:

```
./ips-afp-lab.sh up
```

This will create 2 name spaces environments:

* DUT: The device under test, this is where you'll run Suricata.
* Client: The device that is protected by the DUT.

To enter the DUT:

```
./enter-dut.sh
```

To enter the client:

```
./enter-client.sh
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
	./linux-br.sh up
	```
	
  And to disable the Linux bridge:
  
    ```
	./linux-br.sh down
	```

  Be careful not run Suricata and the Linux bridge at the same
  time. Nothing will break, you just won't be testing what you think
  you are testing.

## Credits

Thanks to Victor Julien for adding the Linux name space tests to our
CI, which these scripts are based off.
