import SwiftUI

// Disambiguates the property wrapper from the SDK 27 State macro.
// Command Line Tools do not ship the SwiftUIMacros plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
