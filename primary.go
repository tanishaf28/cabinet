package main

import (
	"cabinet/config"
	"net/rpc"
	"strconv"
	"sync"
	"time"
)

func establishRPCs() {
	serverConfig := config.ParseClusterConfig(numOfServers, configPath)
	id := config.ServerID

	for i := 0; i < numOfServers; i++ {
		if i == myServerID {
			continue
		}

		serverID, err := strconv.Atoi(serverConfig[i][id])
		if err != nil {
			log.Errorf("%v", err)
			return
		}

		newServer := dialFollower(serverID, serverConfig[i], 10, time.Second)
		if newServer == nil {
			continue // Skip this server but continue with others
		}

		conns.Lock()
		conns.m[serverID] = newServer
		conns.Unlock()
	}

	log.Infof("Successfully established connections to %d followers", len(conns.m))

	go startFollowerReviver(5 * time.Second)
}

// dialFollower dials a single follower, returning nil (never a
// partially-initialized ServerDock) if all attempts fail. Shared by
// establishRPCs (initial connect, which retries hard since followers may
// still be starting up) and startFollowerReviver (a single quick attempt per
// tick, since a still-dead follower just gets retried next tick anyway).
func dialFollower(serverID int, serverRow []string, maxAttempts int, retryDelay time.Duration) *ServerDock {
	ip := config.ServerIP
	portOfRPCListener := config.ServerRPCListenerPort
	addr := serverRow[ip] + ":" + serverRow[portOfRPCListener]

	log.Infof("Connecting to server %d at %v", serverID, addr)

	var txClient *rpc.Client
	var err error
	for retry := 0; retry < maxAttempts; retry++ {
		txClient, err = rpc.Dial("tcp", addr)
		if err == nil {
			break
		}
		if retry < maxAttempts-1 {
			log.Debugf("Connection to %v failed (attempt %d/%d), retrying...", addr, retry+1, maxAttempts)
			time.Sleep(retryDelay)
		}
	}
	if err != nil {
		log.Errorf("txClient rpc.Dial failed to %v after %d attempts | error: %v", addr, maxAttempts, err)
		return nil
	}

	log.Infof("txClient connected to server %d at %v", serverID, addr)
	return &ServerDock{
		serverID: serverID,
		addr:     addr,
		txClient: txClient,
		jobQMu:   sync.RWMutex{},
		jobQ:     map[prioClock]chan struct{}{},
	}
}

// markFollowerFailure counts a failed RPC against conn and, after three
// consecutive failures, evicts it from conns.m. Without this, a follower
// that crashes outside of the scripted crash-injection path (which deletes
// its conns.m entry directly) stays in conns.m forever: the leader keeps
// dialing a dead connection every pClock round, and startFollowerReviver
// never gets a chance to redial it because conns.m still holds an entry.
func markFollowerFailure(conn *ServerDock) {
	const evictThreshold = 3

	conn.failMu.Lock()
	conn.failCount++
	dead := conn.failCount >= evictThreshold
	conn.failMu.Unlock()

	if !dead {
		return
	}

	conns.Lock()
	if conns.m[conn.serverID] == conn { // don't clobber a reviver's fresh reconnect
		delete(conns.m, conn.serverID)
		log.Warnf("[FAILOVER] Follower %d unresponsive (%d consecutive failures) — removed from rotation", conn.serverID, evictThreshold)
	}
	conns.Unlock()
}

// markFollowerSuccess resets the failure count on a successful RPC.
func markFollowerSuccess(conn *ServerDock) {
	conn.failMu.Lock()
	conn.failCount = 0
	conn.failMu.Unlock()
}

// startFollowerReviver periodically redials any follower missing from
// conns.m (evicted by markFollowerFailure, or never connected at startup)
// and re-admits it on success, so a restarted follower rejoins consensus
// instead of being permanently excluded for the life of the leader process.
func startFollowerReviver(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		serverConfig := config.ParseClusterConfig(numOfServers, configPath)
		id := config.ServerID

		for i := 0; i < numOfServers; i++ {
			if i == myServerID {
				continue
			}
			serverID, err := strconv.Atoi(serverConfig[i][id])
			if err != nil {
				continue
			}

			conns.RLock()
			_, alive := conns.m[serverID]
			conns.RUnlock()
			if alive {
				continue
			}

			if newServer := dialFollower(serverID, serverConfig[i], 1, 0); newServer != nil {
				conns.Lock()
				conns.m[serverID] = newServer
				conns.Unlock()
				log.Infof("[FAILOVER] Follower %d reachable again — re-added to rotation", serverID)
			}
		}
	}
}
