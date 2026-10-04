import Foundation
import HealthKit

// MARK: - HKWorkout → `exercises` row (body §12.4, §8.1; DESIGN §B.5 step 4)
// Pure mapping from workout facts (no HealthKit store access), so the logic tests can run it on macOS.

/// What the mapper needs from an `HKWorkout`.
struct WorkoutFacts: Sendable, Equatable {
    var activityType: HKWorkoutActivityType
    var durationSeconds: TimeInterval
    /// Walking/running, cycling or swimming distance (km); nil or 0 = unknown.
    var distanceKm: Double?
    /// `HKMetadataKeyIndoorWorkout`.
    var indoor: Bool = false
    /// `HKMetadataKeySwimmingLocationType`.
    var swimmingLocation: HKWorkoutSwimmingLocationType?
    /// `HKMetadataKeyAverageMETs` in kcal/(hr·kg).
    var averageMETs: Double?
}

struct WorkoutMapping: Sendable, Equatable {
    let activityKey: String
    /// Chinese HealthKit type name (`户外跑步`, `泳池游泳`, …); falls back to the activity's `zh`.
    let description: String
    /// Clamped `HKMetadataKeyAverageMETs`; nil → the server uses the table MET.
    let met: Double?
    /// Minutes, 0.1 precision, 1…1440.
    let durationMin: Double
}

enum WorkoutMapper {
    /// `nil` when the workout is shorter than one minute (the server rejects `duration_min < 1`).
    static func map(_ f: WorkoutFacts) -> WorkoutMapping? {
        guard let minutes = durationMinutes(seconds: f.durationSeconds) else { return nil }
        let met = clampMET(f.averageMETs)
        let key = activityKey(f, durationMin: minutes, met: met)
        let name = description(f) ?? activityZh[key] ?? activityZh["other_moderate"] ?? "运动"
        return WorkoutMapping(activityKey: key, description: String(name.prefix(80)), met: met, durationMin: minutes)
    }

    /// `duration / 60`, rounded to 0.1; nil below 1 minute; at most 1440.
    static func durationMinutes(seconds: TimeInterval) -> Double? {
        guard seconds.isFinite, seconds >= 60 else { return nil }
        let minutes = HealthRound.value(seconds / 60, decimals: 1)
        return min(minutes, 1440)
    }

    /// METs clamped to the server's 1…25.
    static func clampMET(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return HealthRound.value(min(max(v, 1), 25), decimals: 1)
    }

    /// Average speed in km/h, or nil without a distance.
    static func speedKmh(distanceKm: Double?, durationMin: Double) -> Double? {
        guard let d = distanceKm, d > 0, durationMin > 0 else { return nil }
        return d / (durationMin / 60)
    }

    /// `in_device` (body §8.1, §12.4): the workout's energy is already inside the day's `active_kcal` only when the
    /// workout has device energy **and** that day has device active energy. Otherwise the server adds the MET kcal.
    static func inDevice(deviceKcal: Double?, dayActiveKcal: Double?) -> Bool {
        (deviceKcal ?? 0) > 0 && (dayActiveKcal ?? 0) > 0
    }

    /// The client-side table of body §12.4 (v = average speed).
    static func activityKey(_ f: WorkoutFacts, durationMin: Double, met: Double?) -> String {
        let v = speedKmh(distanceKm: f.distanceKm, durationMin: durationMin)
        switch f.activityType {
        case .walking:
            guard let v else { return "walk_moderate" }
            return v < 4.5 ? "walk_slow" : v < 5.5 ? "walk_moderate" : v < 6.4 ? "walk_brisk" : "walk_very_brisk"
        case .running:
            guard let v else { return "jogging" }
            return v < 9 ? "jogging" : v < 11.5 ? "run_10kmh" : v < 14.5 ? "run_13kmh" : "run_16kmh"
        case .cycling:
            if f.indoor { return "cycle_stationary" }
            guard let v else { return "cycle_leisure" }
            return v < 19.5 ? "cycle_leisure" : v < 22.5 ? "cycle_moderate" : "cycle_vigorous"
        case .swimming:
            switch f.swimmingLocation {
            case .openWater: return "swim_open_water"
            case .pool:
                guard let v else { return "swim_leisure" }
                return v < 2.4 ? "swim_freestyle_slow" : v < 3.4 ? "swim_freestyle_medium" : "swim_freestyle_fast"
            default: return "swim_leisure"
            }
        case .hiking: return "hiking"
        case .stairClimbing, .stairs: return "stairs"
        case .jumpRope: return "jump_rope"
        case .basketball: return "basketball"
        case .soccer: return "soccer"
        case .badminton: return "badminton"
        case .tennis: return "tennis_singles"
        case .tableTennis: return "table_tennis"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .traditionalStrengthTraining, .coreTraining: return "strength_moderate"
        case .functionalStrengthTraining: return "strength_vigorous"
        case .crossTraining, .mixedCardio: return "circuit"
        case .highIntensityIntervalTraining: return "hiit"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing_machine"
        case .cardioDance: return "aerobic_dance"
        case .socialDance: return "dance_social"
        case .flexibility, .cooldown, .mindAndBody: return "other_light"
        default:
            if f.activityType.rawValue == legacyDanceRawValue { return "aerobic_dance" }
            return (met ?? 0) >= 6 ? "other_vigorous" : "other_moderate"
        }
    }

    /// `HKWorkoutActivityType.dance` (deprecated in iOS 14, still found in old data).
    static let legacyDanceRawValue: UInt = 14

    /// Chinese name of the HealthKit workout type, with indoor/outdoor and pool/open-water variants.
    static func description(_ f: WorkoutFacts) -> String? {
        switch f.activityType {
        case .walking: return f.indoor ? "室内步行" : "户外步行"
        case .running: return f.indoor ? "室内跑步" : "户外跑步"
        case .cycling: return f.indoor ? "室内骑行" : "户外骑行"
        case .swimming:
            switch f.swimmingLocation {
            case .pool: return "泳池游泳"
            case .openWater: return "开放水域游泳"
            default: return "游泳"
            }
        default:
            if f.activityType.rawValue == legacyDanceRawValue { return "舞蹈" }
            return typeZh[f.activityType.rawValue]
        }
    }

    /// Chinese names of the other workout types (raw value → name).
    static let typeZh: [UInt: String] = [
        HKWorkoutActivityType.americanFootball.rawValue: "美式橄榄球",
        HKWorkoutActivityType.archery.rawValue: "射箭",
        HKWorkoutActivityType.australianFootball.rawValue: "澳式橄榄球",
        HKWorkoutActivityType.badminton.rawValue: "羽毛球",
        HKWorkoutActivityType.baseball.rawValue: "棒球",
        HKWorkoutActivityType.basketball.rawValue: "篮球",
        HKWorkoutActivityType.bowling.rawValue: "保龄球",
        HKWorkoutActivityType.boxing.rawValue: "拳击",
        HKWorkoutActivityType.climbing.rawValue: "攀岩",
        HKWorkoutActivityType.cricket.rawValue: "板球",
        HKWorkoutActivityType.crossTraining.rawValue: "交叉训练",
        HKWorkoutActivityType.curling.rawValue: "冰壶",
        HKWorkoutActivityType.elliptical.rawValue: "椭圆机",
        HKWorkoutActivityType.equestrianSports.rawValue: "马术",
        HKWorkoutActivityType.fencing.rawValue: "击剑",
        HKWorkoutActivityType.fishing.rawValue: "钓鱼",
        HKWorkoutActivityType.functionalStrengthTraining.rawValue: "功能性力量训练",
        HKWorkoutActivityType.golf.rawValue: "高尔夫",
        HKWorkoutActivityType.gymnastics.rawValue: "体操",
        HKWorkoutActivityType.handball.rawValue: "手球",
        HKWorkoutActivityType.hiking.rawValue: "徒步",
        HKWorkoutActivityType.hockey.rawValue: "曲棍球",
        HKWorkoutActivityType.hunting.rawValue: "狩猎",
        HKWorkoutActivityType.lacrosse.rawValue: "长曲棍球",
        HKWorkoutActivityType.martialArts.rawValue: "武术",
        HKWorkoutActivityType.mindAndBody.rawValue: "身心训练",
        HKWorkoutActivityType.paddleSports.rawValue: "桨板运动",
        HKWorkoutActivityType.play.rawValue: "玩耍",
        HKWorkoutActivityType.preparationAndRecovery.rawValue: "准备和恢复",
        HKWorkoutActivityType.racquetball.rawValue: "美式壁球",
        HKWorkoutActivityType.rowing.rawValue: "划船",
        HKWorkoutActivityType.rugby.rawValue: "橄榄球",
        HKWorkoutActivityType.sailing.rawValue: "帆船",
        HKWorkoutActivityType.skatingSports.rawValue: "滑冰",
        HKWorkoutActivityType.snowSports.rawValue: "雪上运动",
        HKWorkoutActivityType.soccer.rawValue: "足球",
        HKWorkoutActivityType.softball.rawValue: "垒球",
        HKWorkoutActivityType.squash.rawValue: "壁球",
        HKWorkoutActivityType.stairClimbing.rawValue: "爬楼梯",
        HKWorkoutActivityType.surfingSports.rawValue: "冲浪",
        HKWorkoutActivityType.tableTennis.rawValue: "乒乓球",
        HKWorkoutActivityType.tennis.rawValue: "网球",
        HKWorkoutActivityType.trackAndField.rawValue: "田径",
        HKWorkoutActivityType.traditionalStrengthTraining.rawValue: "传统力量训练",
        HKWorkoutActivityType.volleyball.rawValue: "排球",
        HKWorkoutActivityType.waterFitness.rawValue: "水中健身",
        HKWorkoutActivityType.waterPolo.rawValue: "水球",
        HKWorkoutActivityType.waterSports.rawValue: "水上运动",
        HKWorkoutActivityType.wrestling.rawValue: "摔跤",
        HKWorkoutActivityType.yoga.rawValue: "瑜伽",
        HKWorkoutActivityType.barre.rawValue: "芭蕾杆",
        HKWorkoutActivityType.coreTraining.rawValue: "核心训练",
        HKWorkoutActivityType.crossCountrySkiing.rawValue: "越野滑雪",
        HKWorkoutActivityType.downhillSkiing.rawValue: "高山滑雪",
        HKWorkoutActivityType.flexibility.rawValue: "柔韧性训练",
        HKWorkoutActivityType.highIntensityIntervalTraining.rawValue: "高强度间歇训练",
        HKWorkoutActivityType.jumpRope.rawValue: "跳绳",
        HKWorkoutActivityType.kickboxing.rawValue: "自由搏击",
        HKWorkoutActivityType.pilates.rawValue: "普拉提",
        HKWorkoutActivityType.snowboarding.rawValue: "单板滑雪",
        HKWorkoutActivityType.stairs.rawValue: "楼梯",
        HKWorkoutActivityType.stepTraining.rawValue: "踏板操",
        HKWorkoutActivityType.wheelchairWalkPace.rawValue: "轮椅（步行速度）",
        HKWorkoutActivityType.wheelchairRunPace.rawValue: "轮椅（跑步速度）",
        HKWorkoutActivityType.taiChi.rawValue: "太极",
        HKWorkoutActivityType.mixedCardio.rawValue: "混合有氧",
        HKWorkoutActivityType.handCycling.rawValue: "手摇车",
        HKWorkoutActivityType.discSports.rawValue: "飞盘运动",
        HKWorkoutActivityType.fitnessGaming.rawValue: "健身游戏",
        HKWorkoutActivityType.cardioDance.rawValue: "有氧舞蹈",
        HKWorkoutActivityType.socialDance.rawValue: "社交舞",
        HKWorkoutActivityType.pickleball.rawValue: "匹克球",
        HKWorkoutActivityType.cooldown.rawValue: "放松",
        HKWorkoutActivityType.swimBikeRun.rawValue: "铁人三项",
        HKWorkoutActivityType.transition.rawValue: "转换",
        HKWorkoutActivityType.underwaterDiving.rawValue: "水下潜水",
    ]

    /// `zh` of the MET table (body §9.1) for the keys this mapper produces (description fallback).
    static let activityZh: [String: String] = [
        "walk_slow": "散步 (约 4 km/h)", "walk_moderate": "步行 (约 5 km/h)", "walk_brisk": "快走 (约 6 km/h)",
        "walk_very_brisk": "疾走 (约 6.8 km/h)", "hiking": "徒步/爬山", "stairs": "爬楼梯", "jogging": "慢跑",
        "run_10kmh": "跑步 (约 10 km/h)", "run_13kmh": "跑步 (约 13 km/h)", "run_16kmh": "跑步 (约 16 km/h)",
        "cycle_leisure": "骑行 (休闲 17–19 km/h)", "cycle_moderate": "骑行 (中速 19–22 km/h)",
        "cycle_vigorous": "骑行 (快速 22–26 km/h)", "cycle_stationary": "动感单车/固定自行车",
        "swim_leisure": "游泳 (休闲，不计圈)", "swim_freestyle_slow": "自由泳 (慢速)", "swim_freestyle_medium": "自由泳 (中速 ~46 m/min)",
        "swim_freestyle_fast": "自由泳 (快速 ~69 m/min)", "swim_open_water": "公开水域游泳", "jump_rope": "跳绳 (中速)",
        "basketball": "篮球 (比赛)", "soccer": "足球 (休闲)", "badminton": "羽毛球 (休闲)", "tennis_singles": "网球单打",
        "table_tennis": "乒乓球", "yoga": "瑜伽 (哈他)", "pilates": "普拉提", "strength_moderate": "力量训练 (中等)",
        "strength_vigorous": "力量训练 (大强度)", "circuit": "循环训练", "hiit": "HIIT 高强度间歇", "elliptical": "椭圆机",
        "rowing_machine": "划船机 (中等)", "aerobic_dance": "有氧操/健身舞", "dance_social": "跳舞 (广场舞/社交舞)",
        "other_light": "其他轻度活动", "other_moderate": "其他中等强度活动", "other_vigorous": "其他高强度活动",
    ]
}
