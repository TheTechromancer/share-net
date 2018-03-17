# ShareNET

###Internet connection sharing made simple with a straight-forward bash script


####Features:
<ul>
    <li>Share ethernet to wireless, vice versa, or any combination</li>
    <li>Supports NAT (fun for avoiding Hotel Wi-Fi fees)</li>
    <li>No arguments are necessary in most cases - it just works!</li>
</ul>

<br>

###Known limitations:
<ul>
    <li>Wi-Fi interface must support AP mode in order to be used as a hotspot</li>
    <li>Wi-Fi interfaces sometimes do not like to be bridged.  Use NAT (the default) instead</li>
</ul>


~~~~

    Usage: share-net.sh [options]

     Options:

            -i      <internet_interface>
            -s      <shared_interface>
            -d      <DHCP subnet> e.g. 10.0.0.0
            -b      enable bridged mode (instead of NAT)

      Programs required:

            dnsmasq hostapd iptables ip

~~~~