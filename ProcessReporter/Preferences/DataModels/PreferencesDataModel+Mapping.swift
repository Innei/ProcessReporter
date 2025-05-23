//
//  PreferencesDataModel+Mapping.swift
//  ProcessReporter
//
//  Created by Innei on 2025/4/21.
//
import Foundation
import RxCocoa
import RxSwift

extension PreferencesDataModel {
	@UserDefaultsRelay("mappingList", defaultValue: MappingList(mappings: []))
	static var mappingList: BehaviorRelay<MappingList>
}

extension PreferencesDataModel {
	enum MappingType: String, CaseIterable, DictionaryConvertible, UserDefaultsJSONStorable, DictionaryConvertibleDelegate {
		static func fromDictionary(_ dict: Any) -> MappingType {
			return self.init(rawValue: dict as! String) ?? .processApplicationIdentifier
		}
	 
		static func fromStorable(_ value: Any?) -> MappingType? {
			guard let value = value else { return nil }
			return fromDictionary(value)
		}
	 
		func toStorable() -> Any? {
			return rawValue
		}
	 
		func toDictionary() -> Any {
			return rawValue
		}

		case processApplicationIdentifier = "process_application_identifier"
		case processName = "process_name"
		case mediaProcessApplicationIdentifier = "media_process_application_identifier"
		case mediaProcessName = "media_process_name"
		
		func toCopyable() -> String {
			switch self {
				case .processApplicationIdentifier:
					return "Process Application Identifier"
				case .mediaProcessName:
					return "Media Process Name"
				case .mediaProcessApplicationIdentifier:
					return "Media Process Application Identifier"
				case .processName:
					return "Process Name"
			}
		}
	}

	struct Mapping: DictionaryConvertible, UserDefaultsJSONStorable, Identifiable {
		var id: String {
			"\(from)-\(to)-\(type.rawValue)"
		}
		
		static func fromDictionary(_ dict: Any) -> Mapping {
			let dict = dict as! [String: Any]
			let type = MappingType.fromDictionary(dict["type"]!)
			let from = dict["from"] as! String
			let to = dict["to"] as! String
			return Mapping(type: type, from: from, to: to)
		}
	 
		let type: MappingType
		let from: String
		let to: String
		
		static func == (lhs: Mapping, rhs: Mapping) -> Bool {
			return lhs.type == rhs.type && lhs.from == rhs.from && lhs.to == rhs.to
		}
	}

	struct MappingList: DictionaryConvertible, UserDefaultsJSONStorable, DictionaryConvertibleDelegate {
		func toDictionary() -> Any {
			return mappings.map { $0.toDictionary() }
		}
	 
		static func fromDictionary(_ dict: Any) -> MappingList {
			let dict = dict as! [[String: Any]]
			let mappings = dict.map { Mapping.fromDictionary($0) }
			return MappingList(mappings: mappings)
		}
	 
		static func fromStorable(_ value: Any?) -> MappingList? {
			guard let value = value else { return nil }
			return fromDictionary(value)
		}
	 
		func toStorable() -> Any? {
			return toDictionary()
		}
	 
		private var mappings: [Mapping] = []
	 
		init(mappings: [Mapping]) {
			self.mappings = mappings
		}
	 
		func getList() -> [Mapping] {
			return mappings
		}

		func addMapping(_ mapping: Mapping) {
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: mappings + [mapping])
			)
		}
		
		func removeMapping(_ mappings: [Mapping]) {
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: self.mappings.filter { item in
					!mappings.contains(where: { $0 == item })
				})
			)
		}

		func editMapping(_ mapping: Mapping, for index: Int) {
			PreferencesDataModel.shared.mappingList.accept(
				MappingList(mappings: mappings.enumerated().map { i, item in
					i == index ? mapping : item
				})
			)
		}
	}
}
