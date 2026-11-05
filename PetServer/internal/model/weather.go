package model

// WeatherHourly 逐小时预报（客户端据此渲染天气卡）
type WeatherHourly struct {
	Time string `json:"time"` // 形如 14:00
	Temp string `json:"temp"`
	Text string `json:"text"`
}

// WeatherDaily 逐日预报
type WeatherDaily struct {
	DayName string `json:"dayName"` // 今天/明天/后天
	TextDay string `json:"textDay"`
	TempMax string `json:"tempMax"`
	TempMin string `json:"tempMin"`
}

// WeatherResult 归一化后的天气数据（客户端直接消费，无需感知上游格式）
type WeatherResult struct {
	City     string          `json:"city"`
	NowTemp  string          `json:"nowTemp"`
	NowText  string          `json:"nowText"`
	TodayMax string          `json:"todayMax"`
	TodayMin string          `json:"todayMin"`
	Hourly   []WeatherHourly `json:"hourly"`
	Daily    []WeatherDaily  `json:"daily"`

	// 服务端 TTL 缓存元信息：Cached=本次命中缓存，UpdatedAt=数据抓取时间（UnixMilli），TTLSec=缓存时长（秒）
	Cached    bool  `json:"cached,omitempty"`
	UpdatedAt int64 `json:"updatedAt,omitempty"`
	TTLSec    int64 `json:"ttlSec,omitempty"`
}
