# WireGuard installer

**This project is a bash script that aims to setup a [WireGuard](https://www.wireguard.com/) VPN on a Linux server, as easily as possible!**

WireGuard is a point-to-point VPN that can be used in different ways. Here, we mean a VPN as in: the users will forward all its traffic trough an encrypted tunnel to the server.
The server will apply NAT by default  to the users traffic so it will appear as if the user is browsing the web with the server's IP.

The script supports both IPv4 and IPv6.

# Table Of Contents

1. [Server Requirements](#Requirements)
2. [Administrators Area](#AdministratorsArea)
    1. [Installation](#Installation)
    2. [Adding users](#Add)
    3. [Revoking/deleting users](#Revoke)
    4. [Resending email to user](#Resend)
    5. [Uninstalling Wireguard](#Uninstall)
3. [Users Area](#UsersArea)
    1. [Downloading Wireguard](#Download)
    2. [Setting up on Windows](#SetupW)
    3. [Setting up on Android](#SetupA)


## Administrators Area <a name="AdministratorsArea"></a>

### Server Requirements <a name="Requirements"></a>

Supported distributions:

- Ubuntu >= 16.04
- Debian >= 10
- Fedora
- CentOS
- Arch Linux
- Oracle Linux

### Installation <a name="Installation"></a>
Clone the repo (as tsg user) and execute next commands as root. Answer the questions asked by the script and it will take care of the rest. **In our case we have a VM (actually havpn.hallon.es) behind our NSX firewall on HPC**. So take care about that, we need all rules on NSX like Port Forwarding, SNAT, etc. You can see the example on HPC Networking & Security panel, on the production NSX ESG service (ESG1).

```bash
##As TSG user
git clone git@github.com:Admin-Hallon/wireguard.git

##As ROOT user
cd /web/hallon/git_projects/wireguard && ./wireguard-install.sh
```

It will install WireGuard (kernel module and tools like qrencode and postfix) on the server, configure it, create a systemd service and a user configuration file and QR code for easy access if you want.


### Adding users <a name="Add"></a>

You should run the script again to add users. So let's do:

```bash
cd /web/hallon/git_projects/wireguard && ./wireguard-install.sh
```

That will prompt you a menu, so, select "Add a new user" option pressing number 1.
```
What do you want to do?
1) Add a new user
2) Revoke existing user
3) Resend email with wireguard config files
4) Uninstall WireGuard
5) Exit
```
It will ask you some details like name, **static ipv4/ipv6 to asign (leave it as is)**, email to send the config files, etc. You will get an email if everything go well.

### Revoking/deleting users <a name="Revoke"></a>

Let's execute again the script:

```bash
cd /web/hallon/git_projects/wireguard && ./wireguard-install.sh
```

On manage menu, select option 2 "Revoke existing user". You will get prompted about what user you want to delete, so press the number.

```
Select the existing client you want to revoke
     1) sfernandez
```

All user config files and lines will be deleted.

### Resending email to user <a name="Resend"></a>

If one user lost email or configuration you can send the email again. So execute the script again:

```bash
cd /web/hallon/git_projects/wireguard && ./wireguard-install.sh
```

Select option 3, "Resend email with wireguard config files". You will be prompted about user email. Remember if you leave it blank it will send to sysadmin@hallon.es

```

```

### Uninstalling Wireguard <a name="Uninstall"></a>

You could uninstall wireguard at all, **you NEVER should do that**. So execute the script and select option 4, "Uninstall WireGuard". It will do all for you.

```bash
cd /web/hallon/git_projects/wireguard && ./wireguard-install.sh
```

You should see an echo on the console like:
```
WireGuard uninstalled successfully
```

## Users Area <a name="UsersArea"></a>

Users need to do some steps to get the VPN running. For them, we attach all needed config files, included one DOCX as simple guide to make the installation easier.

### Downloading Wireguard <a name="Download"></a>

As user, you need to download [WireGuard](https://www.wireguard.com/) depend on your OS. Here a list of some download links:
- [Windows](https://download.wireguard.com/windows-client/wireguard-installer.exe)
- [Mac OS](https://www.wireguard.com/)
- [Android](https://play.google.com/store/apps/details?id=com.wireguard.android)
- [IOS](https://itunes.apple.com/us/app/wireguard/id1451685025?ls=1&mt=12)

</br>

For any ohter distribution, visit [WireGuard Install page](https://www.wireguard.com/install)

### Setting up on Windows 10 <a name="SetupW"></a>
First of all, execute wireguard-installer.exe you downloaded before.
![image](https://user-images.githubusercontent.com/94912518/158191753-271c985d-866c-40a0-9788-3d57fd35975c.png)

When installer finish, open Wireguard and click on *Add Tunnel* or *Import tunnel from file* 
![image](https://user-images.githubusercontent.com/94912518/158192071-e15b6694-f174-4c35-8c6f-aeac7f809a39.png)

Select your .conf you receive on your email. Something like *wg0-client-user.conf*
![image](https://user-images.githubusercontent.com/94912518/158201266-38d4d977-fc87-433f-9cfe-3c17feaf184e.png)

Now you need to do some edits, so clic on "Edit" button.
![image](https://user-images.githubusercontent.com/94912518/159296851-44f28ef4-248c-4f18-b01a-c69445caaf36.png)

Change the connection name (VPN-Hallon ie) if you want and make sure "Block untunneled traffic (kill-switch)” is unticked.
![image](https://user-images.githubusercontent.com/94912518/159297488-1e7eb968-8332-4367-9516-da72d532cb9e.png)

There you go, now you can activate or deactivate the VPN.
![image](https://user-images.githubusercontent.com/94912518/159297575-2d80055f-0192-4076-9c4f-2b6bfe65efad.png)



### Setting up on Android <a name="SetupA"></a>
Make sure you installed the app from play store, open the Wireguard app and touch the + button.
screenshot1

You have 3 ways to import VPN, so select "Scan QR CODE".
screenshot2

Your camera will be automatically opened. Scan the QR you receive on your email and name the connection "HALLON-VPN"
screenshot3

Now you can connect or disconnect from your android phone.
