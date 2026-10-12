package main

import (
    "context"
    "fmt"
    "log"
    "net/http"
    "os"
    "sync"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/joho/godotenv"
    "github.com/redis/go-redis/v9"
)

type Tenant struct {
    ID            string  `json:"id"`
    Name          string  `json:"name"`
    CPUQuota      float64 `json:"cpuQuota"`
    MemoryQuotaMB int     `json:"memoryQuotaMb"`
    DBConnections int     `json:"dbConnections"`
    IsThrottled   bool    `json:"isThrottled"`
}

type Workload struct {
    ID          string    `json:"id"`
    TenantID    string    `json:"tenantId"`
    Cost        float64   `json:"cost"`
    DurationSec int       `json:"durationSec"`
    StartedAt   time.Time `json:"startedAt"`
}

type TenantManager struct {
    mu      sync.Mutex
    tenants map[string]*Tenant
    rdb     *redis.Client
}

func NewTenantManager(rdb *redis.Client) *TenantManager {
    return &TenantManager{
        tenants: map[string]*Tenant{
            "tenant-a": {ID: "tenant-a", Name: "Tenant A", CPUQuota: 0.6, MemoryQuotaMB: 512, DBConnections: 3},
            "tenant-b": {ID: "tenant-b", Name: "Tenant B", CPUQuota: 0.6, MemoryQuotaMB: 512, DBConnections: 3},
            "tenant-c": {ID: "tenant-c", Name: "Tenant C", CPUQuota: 0.5, MemoryQuotaMB: 512, DBConnections: 2},
        },
        rdb: rdb,
    }
}

func (tm *TenantManager) AddTenant(t Tenant) {
    tm.mu.Lock()
    defer tm.mu.Unlock()
    tm.tenants[t.ID] = &t
}

func (tm *TenantManager) ListTenants() []Tenant {
    tm.mu.Lock()
    defer tm.mu.Unlock()

    out := make([]Tenant, 0, len(tm.tenants))
    for _, t := range tm.tenants {
        out = append(out, *t)
    }
    return out
}

func (tm *TenantManager) IsAllowed(tid string, cost float64) bool {
    tm.mu.Lock()
    defer tm.mu.Unlock()

    tenant, ok := tm.tenants[tid]
    if !ok {
        return false
    }

    if tenant.IsThrottled {
        return false
    }

    if cost > tenant.CPUQuota {
        return false
    }

    return true
}

func (tm *TenantManager) ToggleThrottle(tid string, t bool) {
    tm.mu.Lock()
    defer tm.mu.Unlock()

    if tenant, ok := tm.tenants[tid]; ok {
        tenant.IsThrottled = t
    }
}

func main() {
    _ = godotenv.Load()

    gin.SetMode(gin.ReleaseMode)
    r := gin.Default()

    rdb := redis.NewClient(&redis.Options{
        Addr: getEnv("REDIS_URL", "localhost:6379"),
        Password: "",
        DB: 0,
    })

    ctx := context.Background()
    if err := rdb.Ping(ctx).Err(); err != nil {
        log.Printf("redis not available at %s: %v", getEnv("REDIS_URL", "localhost:6379"), err)
    }

    tm := NewTenantManager(rdb)

    r.GET("/health", func(c *gin.Context) {
        c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "tenantguard-api"})
    })

    r.GET("/api/v1/tenants", func(c *gin.Context) {
        c.JSON(http.StatusOK, gin.H{"tenants": tm.ListTenants()})
    })

    r.POST("/api/v1/tenants", func(c *gin.Context) {
        var req Tenant
        if err := c.ShouldBindJSON(&req); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
            return
        }
        if req.ID == "" {
            req.ID = fmt.Sprintf("tenant-%d", time.Now().UnixNano())
        }
        tm.AddTenant(req)
        c.JSON(http.StatusCreated, req)
    })

    r.POST("/api/v1/tenants/:tenantId/throttle", func(c *gin.Context) {
        tenantID := c.Param("tenantId")
        var body struct {
            Enabled bool `json:"enabled"`
        }
        if err := c.ShouldBindJSON(&body); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
            return
        }
        tm.ToggleThrottle(tenantID, body.Enabled)
        c.JSON(http.StatusOK, gin.H{"tenantId": tenantID, "enabled": body.Enabled})
    })

    r.POST("/api/v1/workloads", func(c *gin.Context) {
        var payload struct {
            TenantID    string  `json:"tenantId"`
            Cost        float64 `json:"cost"`
            DurationSec int     `json:"durationSec"`
        }
        if err := c.ShouldBindJSON(&payload); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
            return
        }

        if !tm.IsAllowed(payload.TenantID, payload.Cost) {
            c.JSON(http.StatusForbidden, gin.H{
                "message": "workload rejected by admission policy",
                "tenantId": payload.TenantID,
            })
            return
        }

        workload := Workload{
            ID:          fmt.Sprintf("wrk-%d", time.Now().UnixNano()),
            TenantID:    payload.TenantID,
            Cost:        payload.Cost,
            DurationSec: payload.DurationSec,
            StartedAt:   time.Now(),
        }

        c.JSON(http.StatusAccepted, gin.H{"workload": workload, "status": "queued"})
    })

    r.GET("/api/v1/metrics/tenants", func(c *gin.Context) {
        tenants := tm.ListTenants()
        metrics := make([]gin.H, 0, len(tenants))
        for _, t := range tenants {
            metrics = append(metrics, gin.H{
                "tenantId": t.ID,
                "cpuQuota": t.CPUQuota,
                "memoryQuotaMb": t.MemoryQuotaMB,
                "dbConnections": t.DBConnections,
                "isThrottled": t.IsThrottled,
            })
        }
        c.JSON(http.StatusOK, gin.H{"metrics": metrics})
    })

    port := getEnv("API_PORT", "8080")
    log.Printf("TenantGuard API listening on :%s", port)
    if err := r.Run(":" + port); err != nil {
        log.Fatal(err)
    }
}

func getEnv(key, fallback string) string {
    if v, ok := os.LookupEnv(key); ok && v != "" {
        return v
    }
    return fallback
}
