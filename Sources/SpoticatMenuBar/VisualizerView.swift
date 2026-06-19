import SwiftUI

struct VisualizerView: View {
    let amplitudes: [CGFloat]
    var colors: [Color] = [.cyan, .blue, .purple, .pink] // Default fallback
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: colors),
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask(
            HStack(spacing: 3) {
                // Ensure we don't crash if amplitudes is empty
                if !amplitudes.isEmpty {
                    ForEach(0..<amplitudes.count, id: \.self) { index in
                        Capsule()
                            .frame(width: 3, height: max(4, amplitudes[index] * 40))
                    }
                }
            }
        )
        .shadow(color: colors.first?.opacity(0.3) ?? .clear, radius: 4)
        .frame(height: 40)
        // We rely on the fast update rate from AudioAnalyzer for fluidity
        .animation(.linear(duration: 0.1), value: amplitudes)
        .drawingGroup() 
    }
}

#Preview {
    VisualizerView(amplitudes: [0.1, 0.3, 0.8, 0.4, 0.2, 0.7, 0.9, 0.5, 0.2, 0.6, 0.3, 0.1, 0.2, 0.4, 0.7, 1.0, 0.7, 0.4, 0.2, 0.1, 0.3, 0.6, 0.2, 0.5, 0.9, 0.7, 0.2, 0.4, 0.8, 0.3, 0.1])
        .frame(width: 300, height: 100)
        .background(Color.black)
}
