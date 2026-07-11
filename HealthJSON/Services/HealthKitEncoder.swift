import Foundation
import HealthKit

enum HealthKitEncoder {
    static func batch(
        type: HKSampleType,
        encodedSamples: [[String: Any]],
        deleted: [HKDeletedObject],
        exportedAt: Date = Date()
    ) -> [String: Any] {
        [
            "schemaVersion": 2,
            "mode": "changes",
            "exportedAt": iso8601.string(from: exportedAt),
            "typeIdentifier": type.identifier,
            "added": encodedSamples,
            "deleted": deleted.map { ["uuid": $0.uuid.uuidString.lowercased()] }
        ]
    }

    static func sample(_ healthSample: HKSample, preferredUnits: [HKQuantityType: HKUnit]) -> [String: Any] {
        var result: [String: Any] = [
            "uuid": healthSample.uuid.uuidString.lowercased(),
            "typeIdentifier": healthSample.sampleType.identifier,
            "startDate": iso8601.string(from: healthSample.startDate),
            "endDate": iso8601.string(from: healthSample.endDate),
            "source": [
                "name": healthSample.sourceRevision.source.name,
                "bundleIdentifier": healthSample.sourceRevision.source.bundleIdentifier,
                "version": orNull(healthSample.sourceRevision.version),
                "productType": orNull(healthSample.sourceRevision.productType),
                "operatingSystem": operatingSystem(healthSample.sourceRevision.operatingSystemVersion)
            ],
            "metadata": jsonSafe(healthSample.metadata ?? [:])
        ]

        if let device = healthSample.device {
            let devicePayload: [String: Any] = [
                "name": orNull(device.name),
                "manufacturer": orNull(device.manufacturer),
                "model": orNull(device.model),
                "hardwareVersion": orNull(device.hardwareVersion),
                "firmwareVersion": orNull(device.firmwareVersion),
                "softwareVersion": orNull(device.softwareVersion),
                "localIdentifier": orNull(device.localIdentifier),
                "udiDeviceIdentifier": orNull(device.udiDeviceIdentifier)
            ]
            result["device"] = devicePayload
        }

        switch healthSample {
        case let quantity as HKQuantitySample:
            if let unit = preferredUnits[quantity.quantityType] {
                result["value"] = quantity.quantity.doubleValue(for: unit)
                result["unit"] = unit.unitString
            } else {
                result["quantityDescription"] = quantity.quantity.description
            }
            result["aggregationStyle"] = quantity.quantityType.aggregationStyle.rawValue

        case let category as HKCategorySample:
            result["value"] = category.value

        case let workout as HKWorkout:
            result["workoutActivityType"] = workout.workoutActivityType.rawValue
            result["duration"] = workout.duration
            result["workoutEvents"] = (workout.workoutEvents ?? []).map {
                [
                    "type": $0.type.rawValue,
                    "startDate": iso8601.string(from: $0.dateInterval.start),
                    "endDate": iso8601.string(from: $0.dateInterval.end),
                    "metadata": jsonSafe($0.metadata ?? [:])
                ]
            }
            result["statistics"] = workout.allStatistics.values.map {
                statistics($0, preferredUnits: preferredUnits)
            }
            result["workoutActivities"] = workout.workoutActivities.map { activity in
                var value: [String: Any] = [
                    "uuid": activity.uuid.uuidString.lowercased(),
                    "workoutActivityType": activity.workoutConfiguration.activityType.rawValue,
                    "locationType": activity.workoutConfiguration.locationType.rawValue,
                    "swimmingLocationType": activity.workoutConfiguration.swimmingLocationType.rawValue,
                    "startDate": iso8601.string(from: activity.startDate),
                    "endDate": activity.endDate.map { iso8601.string(from: $0) } ?? NSNull(),
                    "duration": activity.duration,
                    "metadata": jsonSafe(activity.metadata ?? [:]),
                    "statistics": activity.allStatistics.values.map {
                        statistics($0, preferredUnits: preferredUnits)
                    }
                ]
                value["workoutEvents"] = activity.workoutEvents.map {
                    [
                        "type": $0.type.rawValue,
                        "startDate": iso8601.string(from: $0.dateInterval.start),
                        "endDate": iso8601.string(from: $0.dateInterval.end),
                        "metadata": jsonSafe($0.metadata ?? [:])
                    ]
                }
                return value
            }

        case let correlation as HKCorrelation:
            result["objects"] = correlation.objects.map { object in
                Self.sample(object, preferredUnits: preferredUnits)
            }

        case let clinical as HKClinicalRecord:
            result["displayName"] = clinical.displayName
            if let resource = clinical.fhirResource {
                result["fhir"] = (try? JSONSerialization.jsonObject(with: resource.data))
                    ?? ["base64": resource.data.base64EncodedString()]
                result["fhirResourceType"] = resource.resourceType
                result["fhirIdentifier"] = resource.identifier
            }

        case let document as HKCDADocumentSample:
            if let cda = document.document {
                result["title"] = cda.title
                result["patientName"] = cda.patientName
                result["authorName"] = cda.authorName
                result["custodianName"] = cda.custodianName
                result["documentData"] = cda.documentData.map { ["base64": $0.base64EncodedString()] } ?? NSNull()
            }

        case let prescription as HKVisionPrescription:
            result["prescriptionType"] = prescription.prescriptionType.rawValue
            result["dateIssued"] = iso8601.string(from: prescription.dateIssued)
            result["expirationDate"] = prescription.expirationDate.map { iso8601.string(from: $0) } ?? NSNull()

        case let electrocardiogram as HKElectrocardiogram:
            result["classification"] = electrocardiogram.classification.rawValue
            result["symptomsStatus"] = electrocardiogram.symptomsStatus.rawValue
            result["numberOfVoltageMeasurements"] = electrocardiogram.numberOfVoltageMeasurements
            if let rate = electrocardiogram.averageHeartRate {
                let unit = HKUnit.count().unitDivided(by: .minute())
                result["averageHeartRate"] = rate.doubleValue(for: unit)
                result["averageHeartRateUnit"] = unit.unitString
            }

        case let audiogram as HKAudiogramSample:
            result["sensitivityPoints"] = audiogram.sensitivityPoints.map { point in
                let payload: [String: Any] = [
                    "frequencyHz": point.frequency.doubleValue(for: .hertz()),
                    "tests": point.tests.map { test -> [String: Any] in
                        [
                            "sensitivityDbHL": test.sensitivity.doubleValue(for: .decibelHearingLevel()),
                            "conductionType": test.type.rawValue,
                            "side": test.side.rawValue,
                            "masked": test.masked
                        ]
                    }
                ]
                return payload
            }

        case let state as HKStateOfMind:
            result["kind"] = state.kind.rawValue
            result["valence"] = state.valence
            result["labels"] = state.labels.map(\.rawValue)
            result["associations"] = state.associations.map(\.rawValue)

        case let assessment as HKScoredAssessment:
            result["score"] = assessment.score

        case let dose as HKMedicationDoseEvent:
            result["scheduleType"] = dose.scheduleType.rawValue
            result["logStatus"] = dose.logStatus.rawValue
            result["medicationConceptDomain"] = dose.medicationConceptIdentifier.domain.rawValue
            result["scheduledDate"] = dose.scheduledDate.map { iso8601.string(from: $0) } ?? NSNull()
            result["scheduledDoseQuantity"] = orNull(dose.scheduledDoseQuantity)
            result["doseQuantity"] = orNull(dose.doseQuantity)
            result["unit"] = dose.unit.unitString

        default:
            break
        }

        return result
    }

    static func medications(_ medications: [HKUserAnnotatedMedication]) -> [String: Any] {
        let encoded: [[String: Any]] = medications.map { medication in
            [
                "nickname": orNull(medication.nickname),
                "isArchived": medication.isArchived,
                "hasSchedule": medication.hasSchedule,
                "displayText": medication.medication.displayText,
                "generalForm": medication.medication.generalForm.rawValue,
                "conceptDomain": medication.medication.identifier.domain.rawValue,
                "relatedCodings": medication.medication.relatedCodings.map { coding -> [String: Any] in
                    [
                        "system": coding.system,
                        "version": orNull(coding.version),
                        "code": coding.code
                    ]
                }
            ]
        }
        return [
            "schemaVersion": 2,
            "mode": "snapshot",
            "exportedAt": iso8601.string(from: Date()),
            "typeIdentifier": "HKUserAnnotatedMedicationType",
            "added": encoded,
            "deleted": []
        ]
    }

    static func activitySummaries(_ summaries: [HKActivitySummary]) -> [String: Any] {
        let calorie = HKUnit.kilocalorie()
        let minute = HKUnit.minute()
        let count = HKUnit.count()
        let calendar = Calendar(identifier: .gregorian)
        let encoded: [[String: Any]] = summaries.map { summary in
            let day = summary.dateComponents(for: calendar)
            return [
                "date": ["year": orNull(day.year), "month": orNull(day.month), "day": orNull(day.day)],
                "activityMoveMode": summary.activityMoveMode.rawValue,
                "paused": summary.isPaused,
                "activeEnergyBurnedKilocalories": summary.activeEnergyBurned.doubleValue(for: calorie),
                "activeEnergyBurnedGoalKilocalories": summary.activeEnergyBurnedGoal.doubleValue(for: calorie),
                "appleMoveTimeMinutes": summary.appleMoveTime.doubleValue(for: minute),
                "appleMoveTimeGoalMinutes": summary.appleMoveTimeGoal.doubleValue(for: minute),
                "appleExerciseTimeMinutes": summary.appleExerciseTime.doubleValue(for: minute),
                "exerciseTimeGoalMinutes": orNull(summary.exerciseTimeGoal?.doubleValue(for: minute)),
                "appleStandHours": summary.appleStandHours.doubleValue(for: count),
                "standHoursGoal": orNull(summary.standHoursGoal?.doubleValue(for: count))
            ]
        }
        return [
            "schemaVersion": 2,
            "mode": "snapshot",
            "exportedAt": iso8601.string(from: Date()),
            "typeIdentifier": "HKActivitySummaryType",
            "added": encoded,
            "deleted": []
        ]
    }

    static func characteristics(from store: HKHealthStore) -> [String: Any] {
        var values: [String: Any] = [:]
        if let value = try? store.dateOfBirthComponents() {
            let date: [String: Any] = [
                "year": orNull(value.year),
                "month": orNull(value.month),
                "day": orNull(value.day)
            ]
            values["dateOfBirth"] = date
        }
        if let value = try? store.biologicalSex() { values["biologicalSex"] = value.biologicalSex.rawValue }
        if let value = try? store.bloodType() { values["bloodType"] = value.bloodType.rawValue }
        if let value = try? store.fitzpatrickSkinType() { values["fitzpatrickSkinType"] = value.skinType.rawValue }
        if let value = try? store.wheelchairUse() { values["wheelchairUse"] = value.wheelchairUse.rawValue }
        if let value = try? store.activityMoveMode() { values["activityMoveMode"] = value.activityMoveMode.rawValue }
        return [
            "schemaVersion": 2,
            "mode": "snapshot",
            "exportedAt": iso8601.string(from: Date()),
            "typeIdentifier": "HealthKitCharacteristics",
            "added": [values],
            "deleted": []
        ]
    }

    private static func operatingSystem(_ value: OperatingSystemVersion) -> [String: Int] {
        ["major": value.majorVersion, "minor": value.minorVersion, "patch": value.patchVersion]
    }

    private static func statistics(
        _ statistics: HKStatistics,
        preferredUnits: [HKQuantityType: HKUnit]
    ) -> [String: Any] {
        let type = statistics.quantityType
        guard let unit = preferredUnits[type] else {
            return ["typeIdentifier": type.identifier]
        }
        return [
            "typeIdentifier": type.identifier,
            "unit": unit.unitString,
            "sum": orNull(statistics.sumQuantity()?.doubleValue(for: unit)),
            "average": orNull(statistics.averageQuantity()?.doubleValue(for: unit)),
            "minimum": orNull(statistics.minimumQuantity()?.doubleValue(for: unit)),
            "maximum": orNull(statistics.maximumQuantity()?.doubleValue(for: unit)),
            "mostRecent": orNull(statistics.mostRecentQuantity()?.doubleValue(for: unit))
        ]
    }

    private static func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case let date as Date:
            return iso8601.string(from: date)
        case let data as Data:
            return ["base64": data.base64EncodedString()]
        case let url as URL:
            return url.absoluteString
        case let number as NSNumber:
            return number
        case let string as String:
            return string
        case _ as NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
