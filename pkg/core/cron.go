package core

import (
	"fmt"
	"io"
	"os"

	"github.com/robfig/cron"
	log "github.com/sirupsen/logrus"
)

type CronTask struct {
	Name     string
	Schedule string
	Fn       func(io.Writer) error
}

func (server *Server) GetCronTasks() []CronTask {
	cronTasks := []CronTask{
		// ZFS maintenance.
		CronTask{
			Name:     "ZfsMaintenance",
			Schedule: "1 30 7 * * *",
			Fn:       server.sysPerformZfsMaintenance,
		},
		// Orphaned snapshots removal.
		CronTask{
			Name:     "OrphanedSnapshots",
			Schedule: "1 45 * * * *",
			Fn:       server.sysRemoveOrphanedReleaseSnapshots,
		},
		// Hourly NTP sync.
		CronTask{
			Name:     "NtpSync",
			Schedule: "1 1 * * * *",
			Fn:       server.sysSyncNtp,
		},
	}
	return cronTasks
}

func (server *Server) startCrons() {
	c := cron.New()
	log.Infof("[cron] Configuring..")
	for _, cronTask := range server.GetCronTasks() {
		if cronTask.Name == "ZfsMaintenance" && DefaultLXCFS != "zfs" {
			log.Infof(`[cron] Refusing to add ZFS maintenance cron task because the DefaultLXCFS is actually "%v"`, DefaultLXCFS)
			continue
		}
		log.Infof("[cron] Adding cron task %q", cronTask.Name)
		c.AddFunc(cronTask.Schedule, func() {
			logger := NewLogger(os.Stdout, fmt.Sprintf("[%v]", cronTask.Name))
			if err := cronTask.Fn(logger); err != nil {
				log.Errorf("cron: %v ended with error=%v\n", cronTask.Name, err)
			}
		})
	}
	log.Infof("[cron] Starting..")
	c.Start()
	log.Infof("[cron] Cron successfully launched.")
}
