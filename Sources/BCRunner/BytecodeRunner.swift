import CoreGraphics
import Foundation

import BCCommon

extension BCRGBAColor {
  var components: [CGFloat] { [red, green, blue, alpha] }
}

public class BytecodeRunner {
  public enum Error: Swift.Error {
    case outOfBounds(left: BCSizeType, required: BCSizeType)
    case failedToCreateGradient
    case invalidGradientId(id: BCIdType)
    case invalidSubrouteId(id: BCIdType)
  }

  struct State {
    var position: UnsafePointer<UInt8>
    var remaining: BCSizeType
  }

  class Commons {
    var subroutes: [BCIdType: State] = [:]
    var gradients: [BCIdType: CGGradient] = [:]
    let context: CGContext
    let cs: CGColorSpace
    init(_ context: CGContext, _ cs: CGColorSpace) {
      self.cs = cs
      self.context = context
    }
  }

  var currentState: State
  let commons: Commons
  private var gstack: GStateStack

  fileprivate init(_ state: State, _ commons: Commons, gstate: GState) {
    currentState = state
    self.commons = commons
    gstack = GStateStack(initial: gstate)
  }

  func advance(_ count: BCSizeType) {
    currentState.position += Int(count)
    currentState.remaining -= count
  }

  func readInt<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
    let size = MemoryLayout<T>.size
    guard size <= currentState.remaining else {
      throw Error.outOfBounds(
        left: currentState.remaining,
        required: UInt32(size)
      )
    }
    var ret: T = 0
    memcpy(&ret, currentState.position, size)
    advance(BCSizeType(size))
    return T(littleEndian: ret)
  }

  func read<T: BytecodeElement>(_: T.Type = T.self) throws -> T {
    try T.readFrom(self)
  }

  func drawLinearGradient(_ gradient: CGGradient) throws {
    let context = commons.context
    let options: BCLinearGradientDrawingOptions = try read()
    context.drawLinearGradient(
      gradient,
      start: options.start,
      end: options.end,
      options: options.options
    )
  }

  func drawRadialGradient(_ gradient: CGGradient) throws {
    let context = commons.context
    let options: BCRadialGradientDrawingOptions = try read()
    context.drawRadialGradient(
      gradient,
      startCenter: options.startCenter,
      startRadius: options.startRadius,
      endCenter: options.endCenter,
      endRadius: options.endRadius,
      options: options.drawingOptions
    )
  }

  func readGradient() throws -> CGGradient {
    let gradientDesc: BCGradient = try read()
    let sz = gradientDesc.count
    let cs = commons.cs
    let colors = gradientDesc.flatMap(\.color.components)
    let locations = gradientDesc.map(\.location)
    guard let gradient = CGGradient(
      colorSpace: cs,
      colorComponents: colors,
      locations: locations,
      count: sz
    ) else {
      throw Error.failedToCreateGradient
    }
    return gradient
  }

  func readSubroute() throws -> State {
    let sz: BCSizeType = try read()
    guard sz <= currentState.remaining else {
      throw Error.outOfBounds(left: currentState.remaining, required: sz)
    }
    let subroute = State(position: currentState.position, remaining: sz)
    advance(sz)
    return subroute
  }

  func drawShadow() throws {
    let context = commons.context
    let shadow: BCShadow = try read()
    let ctm = context.ctm
    let cs = commons.cs
    let a = ctm.a
    let c = ctm.c
    let scaleX = sqrt(a * a + c * c)
    let offset = shadow.offset.applying(ctm)
    let blur = floor(shadow.blur * scaleX + 0.5)
    let color = CGColor(colorSpace: cs, components: shadow.color.components)
    context.setShadow(offset: offset, blur: blur, color: color)
  }

  func run() throws {
    let context = commons.context

    // MARK: Reading gradients and subroutes

    let gradientCount: BCIdType = try read()
    for _ in 0..<gradientCount {
      let id: BCIdType = try read()
      commons.gradients[id] = try readGradient()
    }

    let subrouteCount: BCIdType = try read()
    for _ in 0..<subrouteCount {
      let id: BCIdType = try read()
      try commons.subroutes[id] = readSubroute()
    }

    // MARK: Executing commands

    while currentState.remaining > 0 {
      let command: Command = try read()
      switch command {
      case .addArc:
        try context.addArc(
          center: read(),
          radius: read(),
          startAngle: read(),
          endAngle: read(),
          clockwise: read()
        )
      case .addEllipse:
        try context.addEllipse(in: read())
      case .appendRectangle:
        try context.addRect(read())
      case .appendRoundedRect:
        let path = try CGPath(
          roundedRect: read(),
          cornerWidth: read(),
          cornerHeight: read(),
          transform: nil
        )
        context.addPath(path)
      case .beginTransparencyLayer:
        context.beginTransparencyLayer(auxiliaryInfo: nil)
      case .blendMode:
        try context.setBlendMode(read())
      case .clip:
        context.clip(using: .init(gstack.fillRule))
      case .clipWithRule:
        try context.clip(using: .init(read(BCFillRule.self)))
      case .clipToRect:
        try context.clip(to: read(CGRect.self))
      case .closePath:
        context.closePath()
      case .colorRenderingIntent:
        try context.setRenderingIntent(read())
      case .concatCTM:
        try context.concatenate(read())
      case .curveTo:
        let curve: BCCubicCurve = try read()
        context.addCurve(
          to: curve.to,
          control1: curve.control1,
          control2: curve.control2
        )
      case .dash:
        gstack.dash = try .init(read())
        context.setDash(gstack.dash)
      case .dashPhase:
        gstack.dash.phase = try read()
        context.setDash(gstack.dash)
      case .dashLenghts:
        gstack.dash.lengths = try read()
        context.setDash(gstack.dash)
      case .drawPath:
        try context.drawPath(using: read())
      case .endTransparencyLayer:
        context.endTransparencyLayer()
      case .fill:
        context.fillPath(using: .init(gstack.fillRule))
      case .fillWithRule:
        try context.fillPath(using: .init(read(BCFillRule.self)))
      case .fillAndStroke:
        let mode: CGPathDrawingMode?
        switch (gstack.stroke.color, gstack.fill.color, gstack.fillRule) {
        case (.some, .some, .winding):
          mode = .fillStroke
        case (.some, .some, .evenOdd):
          mode = .eoFillStroke
        case (nil, .some, .winding):
          mode = .fill
        case (nil, .some, .evenOdd):
          mode = .eoFill
        case (.some, nil, _):
          mode = .stroke
        case (nil, nil, _):
          mode = nil
        }
        if let mode = mode {
          context.drawPath(using: mode)
        } else {
          context.beginPath()
        }
      case .fillColor:
        try gstack.setFillColor(read())
        gstack.fill.rgba.map(context.setFillColor)
      case .fillRule:
        let rule: BCFillRule = try read()
        gstack.fillRule = rule
      case .fillEllipse:
        try context.fillEllipse(in: read())
      case .flatness:
        try context.setFlatness(read())
      case .globalAlpha:
        try context.setAlpha(read())
      case .lineCapStyle:
        try context.setLineCap(read())
      case .lineJoinStyle:
        try context.setLineJoin(read())
      case .lineTo:
        try context.addLine(to: read())
      case .lineWidth:
        try context.setLineWidth(read())
      case .linearGradient:
        let id: BCIdType = try read()
        guard let gradient = commons.gradients[id] else {
          throw Error.invalidGradientId(id: id)
        }
        try drawLinearGradient(gradient)
      case .linearGradientInlined:
        let gradient = try readGradient()
        try drawLinearGradient(gradient)
      case .lines:
        try context.addLines(between: read())
      case .moveTo:
        try context.move(to: read())
      case .radialGradient:
        let id: BCIdType = try read()
        guard let gradient = commons.gradients[id] else {
          throw Error.invalidGradientId(id: id)
        }
        try drawRadialGradient(gradient)
      case .radialGradientInlined:
        let gradient = try readGradient()
        try drawRadialGradient(gradient)
      case .replacePathWithStrokePath:
        context.replacePathWithStrokedPath()
      case .restoreGState:
        gstack.restoreGState()
        context.restoreGState()
      case .saveGState:
        gstack.saveGState()
        context.saveGState()
      case .stroke:
        context.strokePath()
      case .strokeColor:
        try gstack.setStrokeColor(read())
        gstack.stroke.rgba.map(context.setStrokeColor)
      case .subrouteWithId:
        let id: BCIdType = try read()
        guard let subroute = commons.subroutes[id] else {
          throw Error.invalidSubrouteId(id: id)
        }
        try BytecodeRunner(subroute, commons, gstate: gstack.current).run()
      case .shadow:
        try drawShadow()
      case .strokeAlpha:
        try gstack.setStrokeAlpha(read())
        gstack.stroke.rgba.map(context.setStrokeColor)
      case .fillAlpha:
        try gstack.setFillAlpha(read())
        gstack.fill.rgba.map(context.setFillColor)
      case .strokeNone:
        gstack.stroke.color = nil
      case .fillNone:
        gstack.fill.color = nil
      case .setGlobalAlphaToFillAlpha:
        context.setAlpha(gstack.fill.alpha)
      }
    }
  }
}

public func runBytecode(_ context: CGContext, fromData data: Data) throws {
  let sz = data.count
  try data.withUnsafeBytes {
    let ptr = $0.bindMemory(to: UInt8.self).baseAddress!
    try runBytecodeThrowing(context, ptr, sz)
  }
}

func runBytecodeThrowing(
  _ context: CGContext,
  _ start: UnsafePointer<UInt8>,
  _ len: Int
) throws {
  let cs = CGColorSpaceCreateDeviceRGB()
  context.setFillColorSpace(cs)
  context.setStrokeColorSpace(cs)
  let state = BytecodeRunner.State(position: start, remaining: BCSizeType(len))
  let commons = BytecodeRunner.Commons(context, cs)
  try BytecodeRunner(state, commons, gstate: .default).run()
}

@_cdecl("runBytecode")
public func runBytecode(
  _ context: CGContext,
  _ start: UnsafePointer<UInt8>,
  _ len: Int
) {
  do {
    try runBytecodeThrowing(context, start, len)
  } catch let t {
    assertionFailure("Failed to run bytecode with error: \(t)")
  }
}

private struct GState {
  typealias RGBA = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

  struct DashPattern {
    var phase: CGFloat
    var lengths: [CGFloat]?

    init(phase: CGFloat, lengths: [CGFloat]? = nil) {
      self.phase = phase
      self.lengths = lengths
    }

    init(_ bcdash: BCDashPattern) {
      self.phase = bcdash.phase
      self.lengths = bcdash.lengths
    }
  }

  struct Paint {
    var color: BCRGBColor?
    var alpha: CGFloat
    var rgba: RGBA? {
      color.map { ($0.red, $0.green, $0.blue, alpha) }
    }

    static let black = Self(color: .init(r: 0, g: 0, b: 0), alpha: 1)
    static let none = Self(color: nil, alpha: 1)
  }

  var fillRule: BCFillRule
  var fill: Paint
  var stroke: Paint
  var dash: DashPattern

  static let `default` = Self(
    fillRule: .winding,
    fill: .black, stroke: .none,
    dash: .init(phase: 0, lengths: nil)
  )
}

@dynamicMemberLookup
private struct GStateStack {
  private var stack: [GState]
  var current: GState

  init(initial: GState) {
    stack = []
    current = initial
  }

  mutating func saveGState() {
    stack.append(current)
  }

  mutating func restoreGState() {
    if let saved = stack.popLast() {
      current = saved
    }
  }

  subscript<T>(dynamicMember kp: WritableKeyPath<GState, T>) -> T {
    get { current[keyPath: kp] }
    set { current[keyPath: kp] = newValue }
  }

  mutating func setFillColor(_ c: BCRGBColor) {
    current.fill.color = c
  }

  mutating func setFillAlpha(_ alpha: CGFloat) {
    current.fill.alpha = alpha
  }

  mutating func setStrokeColor(_ c: BCRGBColor) {
    current.stroke.color = c
  }

  mutating func setStrokeAlpha(_ alpha: CGFloat) {
    current.stroke.alpha = alpha
  }
}

private func setRGB(to rgba: inout GState.RGBA, from rgb: BCRGBColor) {
  rgba.red = rgb.red
  rgba.green = rgb.green
  rgba.blue = rgb.blue
}

extension CGContext {
  fileprivate func setFillColor(_ rgba: GState.RGBA) {
    setFillColor(
      red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha
    )
  }

  fileprivate func setStrokeColor(_ rgba: GState.RGBA) {
    setStrokeColor(
      red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha
    )
  }

  fileprivate func setDash(_ dash: GState.DashPattern) {
    guard let lenghts = dash.lengths else { return }
    setLineDash(phase: dash.phase, lengths: lenghts)
  }
}

extension CGPathFillRule {
  init(_ bc: BCFillRule) {
    switch bc {
    case .winding:
      self = .winding
    case .evenOdd:
      self = .evenOdd
    }
  }
}
