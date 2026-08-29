import HealthKit

enum HealthDataCatalog {
    static var sampleTypes: [HKSampleType] {
        var types: [HKSampleType] = []
        types += quantityIdentifiers.compactMap {
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: $0))
        }
        types += categoryIdentifiers.compactMap {
            HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: $0))
        }
        types += scoredAssessmentIdentifiers.map {
            HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: $0))
        }
        types.append(HKObjectType.workoutType())
        types.append(HKSeriesType.workoutRoute())
        types.append(HKSeriesType.heartbeat())
        types.append(HKObjectType.audiogramSampleType())
        types.append(HKObjectType.electrocardiogramType())
        types.append(HKObjectType.stateOfMindType())

        return Dictionary(grouping: types, by: \.identifier)
            .compactMap(\.value.first)
            .sorted { $0.identifier < $1.identifier }
    }

    static var readTypes: Set<HKObjectType> {
        let directlyAuthorizableSamples = sampleTypes
        return Set(directlyAuthorizableSamples.map { $0 as HKObjectType } + characteristicTypes + [
            HKObjectType.activitySummaryType()
        ])
    }

    static var quantityTypes: [HKQuantityType] {
        sampleTypes.compactMap { $0 as? HKQuantityType }
    }

    static var categoryTypes: [HKCategoryType] {
        sampleTypes.compactMap { $0 as? HKCategoryType }
    }

    static var backgroundDeliveryTypes: [HKSampleType] {
        sampleTypes.filter {
            $0 is HKQuantityType
                || $0 is HKCategoryType
                || $0 == HKObjectType.workoutType()
        }
    }

    private static let characteristicTypes: [HKCharacteristicType] = [
        HKObjectType.characteristicType(forIdentifier: .dateOfBirth),
        HKObjectType.characteristicType(forIdentifier: .biologicalSex),
        HKObjectType.characteristicType(forIdentifier: .bloodType),
        HKObjectType.characteristicType(forIdentifier: .fitzpatrickSkinType),
        HKObjectType.characteristicType(forIdentifier: .wheelchairUse),
        HKObjectType.characteristicType(forIdentifier: .activityMoveMode)
    ].compactMap { $0 }

    private static let scoredAssessmentIdentifiers = [
        "HKScoredAssessmentTypeIdentifierGAD7",
        "HKScoredAssessmentTypeIdentifierPHQ9"
    ]

    private static let quantityIdentifiers = [
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
        "HKQuantityTypeIdentifierBodyFatPercentage",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyMassIndex",
        "HKQuantityTypeIdentifierElectrodermalActivity",
        "HKQuantityTypeIdentifierHeight",
        "HKQuantityTypeIdentifierLeanBodyMass",
        "HKQuantityTypeIdentifierWaistCircumference",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierAppleMoveTime",
        "HKQuantityTypeIdentifierAppleStandTime",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierCrossCountrySkiingSpeed",
        "HKQuantityTypeIdentifierCyclingCadence",
        "HKQuantityTypeIdentifierCyclingFunctionalThresholdPower",
        "HKQuantityTypeIdentifierCyclingPower",
        "HKQuantityTypeIdentifierCyclingSpeed",
        "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",
        "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
        "HKQuantityTypeIdentifierDistancePaddleSports",
        "HKQuantityTypeIdentifierDistanceRowing",
        "HKQuantityTypeIdentifierDistanceSkatingSports",
        "HKQuantityTypeIdentifierDistanceSwimming",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierDistanceWheelchair",
        "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierNikeFuel",
        "HKQuantityTypeIdentifierPaddleSportsSpeed",
        "HKQuantityTypeIdentifierPhysicalEffort",
        "HKQuantityTypeIdentifierPushCount",
        "HKQuantityTypeIdentifierRowingSpeed",
        "HKQuantityTypeIdentifierRunningPower",
        "HKQuantityTypeIdentifierRunningSpeed",
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierSwimmingStrokeCount",
        "HKQuantityTypeIdentifierUnderwaterDepth",
        "HKQuantityTypeIdentifierWorkoutEffortScore",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
        "HKQuantityTypeIdentifierEnvironmentalSoundReduction",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure",
        "HKQuantityTypeIdentifierAtrialFibrillationBurden",
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierPeripheralPerfusionIndex",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierVO2Max",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness",
        "HKQuantityTypeIdentifierRunningGroundContactTime",
        "HKQuantityTypeIdentifierRunningStrideLength",
        "HKQuantityTypeIdentifierRunningVerticalOscillation",
        "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",
        "HKQuantityTypeIdentifierStairAscentSpeed",
        "HKQuantityTypeIdentifierStairDescentSpeed",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
        "HKQuantityTypeIdentifierWalkingSpeed",
        "HKQuantityTypeIdentifierWalkingStepLength",
        "HKQuantityTypeIdentifierDietaryBiotin",
        "HKQuantityTypeIdentifierDietaryCaffeine",
        "HKQuantityTypeIdentifierDietaryCalcium",
        "HKQuantityTypeIdentifierDietaryCarbohydrates",
        "HKQuantityTypeIdentifierDietaryChloride",
        "HKQuantityTypeIdentifierDietaryCholesterol",
        "HKQuantityTypeIdentifierDietaryChromium",
        "HKQuantityTypeIdentifierDietaryCopper",
        "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "HKQuantityTypeIdentifierDietaryFatMonounsaturated",
        "HKQuantityTypeIdentifierDietaryFatPolyunsaturated",
        "HKQuantityTypeIdentifierDietaryFatSaturated",
        "HKQuantityTypeIdentifierDietaryFatTotal",
        "HKQuantityTypeIdentifierDietaryFiber",
        "HKQuantityTypeIdentifierDietaryFolate",
        "HKQuantityTypeIdentifierDietaryIodine",
        "HKQuantityTypeIdentifierDietaryIron",
        "HKQuantityTypeIdentifierDietaryMagnesium",
        "HKQuantityTypeIdentifierDietaryManganese",
        "HKQuantityTypeIdentifierDietaryMolybdenum",
        "HKQuantityTypeIdentifierDietaryNiacin",
        "HKQuantityTypeIdentifierDietaryPantothenicAcid",
        "HKQuantityTypeIdentifierDietaryPhosphorus",
        "HKQuantityTypeIdentifierDietaryPotassium",
        "HKQuantityTypeIdentifierDietaryProtein",
        "HKQuantityTypeIdentifierDietaryRiboflavin",
        "HKQuantityTypeIdentifierDietarySelenium",
        "HKQuantityTypeIdentifierDietarySodium",
        "HKQuantityTypeIdentifierDietarySugar",
        "HKQuantityTypeIdentifierDietaryThiamin",
        "HKQuantityTypeIdentifierDietaryVitaminA",
        "HKQuantityTypeIdentifierDietaryVitaminB12",
        "HKQuantityTypeIdentifierDietaryVitaminB6",
        "HKQuantityTypeIdentifierDietaryVitaminC",
        "HKQuantityTypeIdentifierDietaryVitaminD",
        "HKQuantityTypeIdentifierDietaryVitaminE",
        "HKQuantityTypeIdentifierDietaryVitaminK",
        "HKQuantityTypeIdentifierDietaryWater",
        "HKQuantityTypeIdentifierDietaryZinc",
        "HKQuantityTypeIdentifierBloodAlcoholContent",
        "HKQuantityTypeIdentifierBloodPressureDiastolic",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKQuantityTypeIdentifierInsulinDelivery",
        "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages",
        "HKQuantityTypeIdentifierNumberOfTimesFallen",
        "HKQuantityTypeIdentifierTimeInDaylight",
        "HKQuantityTypeIdentifierUVExposure",
        "HKQuantityTypeIdentifierWaterTemperature",
        "HKQuantityTypeIdentifierBasalBodyTemperature",
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",
        "HKQuantityTypeIdentifierForcedExpiratoryVolume1",
        "HKQuantityTypeIdentifierForcedVitalCapacity",
        "HKQuantityTypeIdentifierInhalerUsage",
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierPeakExpiratoryFlowRate",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKQuantityTypeIdentifierBloodGlucose",
        "HKQuantityTypeIdentifierBodyTemperature"
    ]

    private static let categoryIdentifiers = [
        "HKCategoryTypeIdentifierAppleStandHour",
        "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent",
        "HKCategoryTypeIdentifierHeadphoneAudioExposureEvent",
        "HKCategoryTypeIdentifierHighHeartRateEvent",
        "HKCategoryTypeIdentifierHypertensionEvent",
        "HKCategoryTypeIdentifierIrregularHeartRhythmEvent",
        "HKCategoryTypeIdentifierLowCardioFitnessEvent",
        "HKCategoryTypeIdentifierLowHeartRateEvent",
        "HKCategoryTypeIdentifierMindfulSession",
        "HKCategoryTypeIdentifierAppleWalkingSteadinessEvent",
        "HKCategoryTypeIdentifierHandwashingEvent",
        "HKCategoryTypeIdentifierToothbrushingEvent",
        "HKCategoryTypeIdentifierBleedingAfterPregnancy",
        "HKCategoryTypeIdentifierBleedingDuringPregnancy",
        "HKCategoryTypeIdentifierCervicalMucusQuality",
        "HKCategoryTypeIdentifierContraceptive",
        "HKCategoryTypeIdentifierInfrequentMenstrualCycles",
        "HKCategoryTypeIdentifierIntermenstrualBleeding",
        "HKCategoryTypeIdentifierIrregularMenstrualCycles",
        "HKCategoryTypeIdentifierLactation",
        "HKCategoryTypeIdentifierMenstrualFlow",
        "HKCategoryTypeIdentifierOvulationTestResult",
        "HKCategoryTypeIdentifierPersistentIntermenstrualBleeding",
        "HKCategoryTypeIdentifierPregnancy",
        "HKCategoryTypeIdentifierPregnancyTestResult",
        "HKCategoryTypeIdentifierProgesteroneTestResult",
        "HKCategoryTypeIdentifierProlongedMenstrualPeriods",
        "HKCategoryTypeIdentifierSexualActivity",
        "HKCategoryTypeIdentifierSleepApneaEvent",
        "HKCategoryTypeIdentifierSleepAnalysis",
        "HKCategoryTypeIdentifierAbdominalCramps",
        "HKCategoryTypeIdentifierAcne",
        "HKCategoryTypeIdentifierAppetiteChanges",
        "HKCategoryTypeIdentifierBladderIncontinence",
        "HKCategoryTypeIdentifierBloating",
        "HKCategoryTypeIdentifierBreastPain",
        "HKCategoryTypeIdentifierChestTightnessOrPain",
        "HKCategoryTypeIdentifierChills",
        "HKCategoryTypeIdentifierConstipation",
        "HKCategoryTypeIdentifierCoughing",
        "HKCategoryTypeIdentifierDiarrhea",
        "HKCategoryTypeIdentifierDizziness",
        "HKCategoryTypeIdentifierDrySkin",
        "HKCategoryTypeIdentifierFainting",
        "HKCategoryTypeIdentifierFatigue",
        "HKCategoryTypeIdentifierFever",
        "HKCategoryTypeIdentifierGeneralizedBodyAche",
        "HKCategoryTypeIdentifierHairLoss",
        "HKCategoryTypeIdentifierHeadache",
        "HKCategoryTypeIdentifierHeartburn",
        "HKCategoryTypeIdentifierHotFlashes",
        "HKCategoryTypeIdentifierLossOfSmell",
        "HKCategoryTypeIdentifierLossOfTaste",
        "HKCategoryTypeIdentifierLowerBackPain",
        "HKCategoryTypeIdentifierMemoryLapse",
        "HKCategoryTypeIdentifierMoodChanges",
        "HKCategoryTypeIdentifierNausea",
        "HKCategoryTypeIdentifierNightSweats",
        "HKCategoryTypeIdentifierPelvicPain",
        "HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat",
        "HKCategoryTypeIdentifierRunnyNose",
        "HKCategoryTypeIdentifierShortnessOfBreath",
        "HKCategoryTypeIdentifierSinusCongestion",
        "HKCategoryTypeIdentifierSkippedHeartbeat",
        "HKCategoryTypeIdentifierSleepChanges",
        "HKCategoryTypeIdentifierSoreThroat",
        "HKCategoryTypeIdentifierVaginalDryness",
        "HKCategoryTypeIdentifierVomiting",
        "HKCategoryTypeIdentifierWheezing",
        "HKCategoryTypeIdentifierAudioExposureEvent"
    ]
}
