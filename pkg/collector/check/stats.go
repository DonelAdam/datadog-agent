// Unless explicitly stated otherwise all files in this repository are licensed
// under the Apache License Version 2.0.
// This product includes software developed at Datadog (https://www.datadoghq.com/).
// Copyright 2016-2019 Datadog, Inc.

package check

import (
	"sync"
	"time"

	"github.com/DataDog/datadog-agent/pkg/telemetry"
)

var (
	tlmMetricsSamples = telemetry.NewCounter(
		"agent", "checks", "metrics_samples",
		[]string{"id", "name", "version"},
		"Metrics count",
	)
	tlmEvents = telemetry.NewCounter(
		"agent", "checks", "events",
		[]string{"id", "name", "version"},
		"Events count",
	)
	tlmServices = telemetry.NewCounter(
		"agent", "checks", "services_checks",
		[]string{"id", "name", "version"},
		"Service checks count",
	)
	tlmExecutionTime = telemetry.NewGauge(
		"agent", "checks", "execution_time",
		[]string{"id", "name", "version"},
		"Check execution time",
	)
)

// Stats holds basic runtime statistics about check instances
type Stats struct {
	CheckName            string
	CheckVersion         string
	CheckConfigSource    string
	CheckID              ID
	TotalRuns            uint64
	TotalErrors          uint64
	TotalWarnings        uint64
	MetricSamples        int64
	Events               int64
	ServiceChecks        int64
	TotalMetricSamples   int64
	TotalEvents          int64
	TotalServiceChecks   int64
	ExecutionTimes       [32]int64 // circular buffer of recent run durations, most recent at [(TotalRuns+31) % 32]
	AverageExecutionTime int64     // average run duration
	LastExecutionTime    int64     // most recent run duration, provided for convenience
	LastError            string    // error that occurred in the last run, if any
	LastWarnings         []string  // warnings that occurred in the last run, if any
	UpdateTimestamp      int64     // latest update to this instance, unix timestamp in seconds
	m                    sync.Mutex
}

// NewStats returns a new check stats instance
func NewStats(c Check) *Stats {
	return &Stats{
		CheckID:           c.ID(),
		CheckName:         c.String(),
		CheckVersion:      c.Version(),
		CheckConfigSource: c.ConfigSource(),
	}
}

// Add tracks a new execution time
func (cs *Stats) Add(t time.Duration, err error, warnings []error, metricStats map[string]int64) {
	cs.m.Lock()
	defer cs.m.Unlock()

	// store execution times in Milliseconds
	tms := t.Nanoseconds() / 1e6
	cs.LastExecutionTime = tms
	tlmExecutionTime.Set(float64(tms), string(cs.CheckID), cs.CheckName, cs.CheckVersion)
	cs.ExecutionTimes[cs.TotalRuns%uint64(len(cs.ExecutionTimes))] = tms
	cs.TotalRuns++
	var totalExecutionTime int64
	ringSize := cs.TotalRuns
	if ringSize > uint64(len(cs.ExecutionTimes)) {
		ringSize = uint64(len(cs.ExecutionTimes))
	}
	for i := uint64(0); i < ringSize; i++ {
		totalExecutionTime += cs.ExecutionTimes[i]
	}
	cs.AverageExecutionTime = totalExecutionTime / int64(ringSize)
	if err != nil {
		cs.TotalErrors++
		cs.LastError = err.Error()
	} else {
		cs.LastError = ""
	}
	cs.LastWarnings = []string{}
	if len(warnings) != 0 {
		for _, w := range warnings {
			cs.TotalWarnings++
			cs.LastWarnings = append(cs.LastWarnings, w.Error())
		}
	}
	cs.UpdateTimestamp = time.Now().Unix()

	if m, ok := metricStats["MetricSamples"]; ok {
		cs.MetricSamples = m
		if cs.TotalMetricSamples <= 1000001 {
			cs.TotalMetricSamples += m
			tlmMetricsSamples.Add(float64(m), string(cs.CheckID), cs.CheckName, cs.CheckVersion)
		}
	}
	if ev, ok := metricStats["Events"]; ok {
		cs.Events = ev
		if cs.TotalEvents <= 1000001 {
			cs.TotalEvents += ev
			tlmEvents.Add(float64(ev), string(cs.CheckID), cs.CheckName, cs.CheckVersion)
		}
	}
	if sc, ok := metricStats["ServiceChecks"]; ok {
		cs.ServiceChecks = sc
		if cs.TotalServiceChecks <= 1000001 {
			cs.TotalServiceChecks += sc
			tlmServices.Add(float64(sc), string(cs.CheckID), cs.CheckName, cs.CheckVersion)
		}
	}
}
