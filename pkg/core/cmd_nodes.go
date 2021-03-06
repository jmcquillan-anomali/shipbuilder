package core

import (
	"fmt"
	"io"
	"net"
	"strings"
)

func (server *Server) SyncContainer(e Executor, address string, container string, cloneOrCreateArgs ...string) error {
	cmd := fmt.Sprintf("sudo lxc launch %[1]v:%[2]v %[2]v", DefaultSSHHost, container)
	if err := e.Run("ssh", DEFAULT_NODE_USERNAME+"@"+address, cmd); err != nil {
		return err
	}
	return nil
	// {
	// 	cmd := fmt.Sprintf("sudo lxc-ls -1 | grep '^%[1]v$' && ( sudo lxc-stop -k -n %[1]v ; sudo lxc-destroy -n %[1]v )", container)
	// 	e.Run("ssh", DEFAULT_NODE_USERNAME+"@"+address, cmd)
	// }

	// if len(cloneOrCreateArgs) > 0 {
	// 	cloneOrCreateArgs = append([]string{"||", "sudo"}, cloneOrCreateArgs...)
	// }

	// if err := e.Run("ssh", append(
	// 	[]string{
	// 		DEFAULT_NODE_USERNAME + "@" + address,
	// 		"sudo", "test", "-e", LXC_DIR + "/" + container, "&&",
	// 		"echo", "not creating/cloning image '" + container + "', already exists",
	// 	},
	// 	cloneOrCreateArgs...,
	// )...); err != nil {
	// 	return err
	// }

	// // if err := e.RsyncTo("root@"+address, "/var/cache/lx*", "/var/cache/"); err != nil {
	// // 	return err
	// // }

	// {
	// 	path := LXC_DIR + "/" + container
	// 	if DefaultLXCFS == "zfs" {
	// 		// Trim leading slash.
	// 		path = strings.TrimLeft(path, "/")
	// 		// NB: This mounting business is a new requirement for the LXC 2.x series.
	// 		if err := e.Run("sudo", "zfs", "mount", path); err != nil {
	// 			return fmt.Errorf("mounting zfs path %q: %s", path, err)
	// 		}
	// 		defer func() {
	// 			if err := e.Run("sudo", "zfs", "umount", path); err != nil {
	// 				log.Errorf("Problem unmounting path %q: %s", path, err)
	// 			}
	// 		}()
	// 	}
	// }

	// // Rsync the base container over.
	// if err := e.RsyncTo("root@"+address, LXC_DIR+"/"+container+"/rootfs/", LXC_DIR+"/base/rootfs/"); err != nil {
	// 	return err
	// }
	// return nil
}

func (server *Server) addNode(addAddress string, logger io.Writer) (string, error) {
	// var (
	// 	prefixLogger = NewLogger(logger, "["+addAddress+"] ")
	// 	e            = Executor{
	// 		logger: prefixLogger,
	// 	}
	// )

	// fmt.Fprintf(prefixLogger, "Transmitting base LXC container image to node: %v\n", addAddress)
	// if err := server.SyncContainer(e, addAddress, "base", "lxc", "launch", "base", "-B", DefaultLXCFS, "-t", "ubuntu"); err != nil {
	// 	return addAddress, err
	// }
	// // Add build-packs.
	// for _, buildPack := range server.BuildpacksProvider.All() {
	// 	nContainer := "base-" + buildPack.Name()
	// 	fmt.Fprintf(prefixLogger, "Transmitting build-pack '%v' LXC container image to node: %v\n", nContainer, addAddress)
	// 	if err := server.SyncContainer(e, addAddress, nContainer, "lxc-clone", "-s", "-B", DefaultLXCFS, "-o", "base", "-n", nContainer); err != nil {
	// 		return addAddress, err
	// 	}
	// }
	return addAddress, nil
}

// Require that the node name does not contain the word "backend",
// as it would break Server.dynoRoutingActive().
func (server *Server) validateNodeNames(addresses *[]string) error {
	for _, address := range *addresses {
		if strings.Contains(strings.ToLower(address), "backend") {
			return fmt.Errorf(`Invalid name "%v", must not contain "backend"`, address)
		}
	}
	return nil
}

func (server *Server) Node_Add(conn net.Conn, addresses []string) error {
	err := server.validateNodeNames(&addresses)
	if err != nil {
		return err
	}

	type AddResult struct {
		address string
		err     error
	}

	addChannel := make(chan AddResult)

	addNodeWrapper := func(addAddress string, logger io.Writer) {
		result, err := server.addNode(addAddress, logger)
		addChannel <- AddResult{result, err}
	}

	addresses = replaceLocalhostWithSystemIp(&addresses)

	titleLogger, dimLogger := server.getTitleAndDimLoggers(conn)

	fmt.Fprintf(titleLogger, "=== Adding Nodes\n\n")

	return server.WithPersistentConfig(func(cfg *Config) error {
		numRemaining := 0

		for _, addAddress := range addresses {
			// Ensure the node to be added is not empty and that it isn't already added.
			if len(addAddress) == 0 {
				continue
			}
			found := false
			for _, node := range cfg.Nodes {
				if strings.ToLower(node.Host) == strings.ToLower(addAddress) {
					fmt.Fprintf(dimLogger, "Node already exists: %v\n", addAddress)
					found = true
					break
				}
			}
			if found {
				continue
			}

			go addNodeWrapper(addAddress, dimLogger)
			numRemaining++
		}

		if numRemaining > 0 {
		OUTER:
			for {
				select {
				case result := <-addChannel:
					if result.err != nil {
						fmt.Fprintf(titleLogger, "Failed to add node '%v': %v\n", result.address, result.err)
					} else {
						fmt.Fprintf(titleLogger, "Adding node: %v\n", result.address)
						cfg.Nodes = append(cfg.Nodes, &Node{result.address})
					}
					numRemaining--
					if numRemaining == 0 {
						break OUTER
					}
				}
			}
		}
		return nil
	})
}

func (server *Server) Node_List(conn net.Conn) error {
	titleLogger, dimLogger := server.getTitleAndDimLoggers(conn)

	fmt.Fprintf(titleLogger, "=== System Nodes\n\n")

	return server.WithConfig(func(cfg *Config) error {
		for _, node := range cfg.Nodes {
			nodeStatus := server.getNodeStatus(node)
			if nodeStatus.Err == nil {
				fmt.Fprintf(dimLogger, "%v (%vMB free)\n", node.Host, nodeStatus.FreeMemoryMb)
				for _, application := range nodeStatus.Containers {
					fmt.Fprintf(dimLogger, "    `- %v\n", application)
				}
			} else {
				fmt.Fprintf(dimLogger, "%v (unknown status: %v since %v)\n", node.Host, nodeStatus.Err, nodeStatus.Ts)
			}

		}
		return nil
	})
}

func (server *Server) Node_Remove(conn net.Conn, addresses []string) error {
	addresses = replaceLocalhostWithSystemIp(&addresses)

	titleLogger, dimLogger := server.getTitleAndDimLoggers(conn)

	fmt.Fprintf(titleLogger, "=== Removing Nodes\n\n")

	return server.WithPersistentConfig(func(cfg *Config) error {
		nNodes := []*Node{}
		for _, node := range cfg.Nodes {
			keep := true
			for _, removeAddress := range addresses {
				if strings.ToLower(removeAddress) == strings.ToLower(node.Host) {
					fmt.Fprintf(dimLogger, "Removing node: %v\n", removeAddress)
					keep = false
					break
				}
			}
			if keep {
				nNodes = append(nNodes, node)
			}
		}
		cfg.Nodes = nNodes
		return nil
	})
}

func (e Executor) RsyncTo(host string, src string, dst string) error {
	if err := e.Run("sudo", "rsync",
		"--recursive",
		"--links",
		"--perms",
		"--times",
		"--devices",
		"--specials",
		"--owner",
		"--group",
		"--hard-links",
		"--acls",
		"--delete",
		"--xattrs",
		"--numeric-ids",
		"-e", "ssh "+DEFAULT_SSH_PARAMETERS,
		src,
		host+":"+dst,
	); err != nil {
		return fmt.Errorf("rsyncing %v to %v:%v: %s", src, host, dst, err)
	}
	return nil
}
