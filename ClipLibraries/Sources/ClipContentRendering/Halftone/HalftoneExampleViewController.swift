//
//  HalftoneExampleViewController.swift
//  HalftoneEffect — example / integration reference
//
//  This file is OPTIONAL. It shows three things:
//    1. Applying the effect to an image view in one line.
//    2. Driving a complex animation *behind* the effect to prove it stays smooth.
//    3. Live-tweaking parameters with on-screen controls.
//
//  Drop it into a sample app and set it as the root view controller, or copy the
//  bits you need.
//

import UIKit

final class HalftoneExampleViewController: UIViewController {

    private let canvas = UIView()
    private let imageView = UIImageView()
    private var effect: HalftoneEffectView?

    private let cellSlider = UISlider()
    private let radiusSlider = UISlider()
    private let dotScaleSlider = UISlider()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // --- The content we want to "dot-ify". Any UIView works; here it's an
        //     image view with a couple of animated sublayers on top so you can see
        //     that live Core Animation flows through the effect. -------------------
        canvas.frame = CGRect(x: 16, y: 80, width: view.bounds.width - 32, height: 420)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        canvas.backgroundColor = .black
        canvas.clipsToBounds = true
        view.addSubview(canvas)

        imageView.frame = canvas.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.image = UIImage(named: "lotus") // supply your own asset
        imageView.backgroundColor = .black
        canvas.addSubview(imageView)

        addBouncingBlobs(to: canvas)   // complex animation behind the dots

        // --- Apply the effect. One line. ---------------------------------------
        effect = canvas.applyHalftone { c in
            c.cellSize     = 16
            c.dotScale     = 0.84
            c.shape        = .roundedSquare(cornerRadius: 0.30)
            c.gapColor     = .black
            c.averageCell  = true
            c.brightnessBoost = 1.05
        }

        setupControls()
        startContentAnimation()
    }

    // MARK: Complex animation behind the effect

    private func addBouncingBlobs(to host: UIView) {
        for i in 0..<6 {
            let blob = CALayer()
            let s = CGFloat(40 + i * 14)
            blob.frame = CGRect(x: 0, y: 0, width: s, height: s)
            blob.cornerRadius = s / 2
            blob.backgroundColor = UIColor(hue: CGFloat(i) / 6.0,
                                           saturation: 0.9, brightness: 1.0, alpha: 0.9).cgColor
            blob.position = CGPoint(x: .random(in: 0...host.bounds.width),
                                    y: .random(in: 0...host.bounds.height))
            host.layer.addSublayer(blob)

            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.path = randomLoopPath(in: host.bounds).cgPath
            anim.duration = Double.random(in: 4...8)
            anim.repeatCount = .infinity
            anim.calculationMode = .paced
            blob.add(anim, forKey: "drift")
        }
    }

    private func randomLoopPath(in rect: CGRect) -> UIBezierPath {
        let p = UIBezierPath()
        let start = CGPoint(x: .random(in: 0...rect.width), y: .random(in: 0...rect.height))
        p.move(to: start)
        for _ in 0..<4 {
            p.addLine(to: CGPoint(x: .random(in: 0...rect.width),
                                  y: .random(in: 0...rect.height)))
        }
        p.close()
        return p
    }

    private func startContentAnimation() {
        // Gentle zoom/pan of the image to mimic the reference video.
        UIView.animate(withDuration: 6, delay: 0,
                       options: [.autoreverse, .repeat, .curveEaseInOut]) {
            self.imageView.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        }
    }

    // MARK: Live controls

    private func setupControls() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        func labelled(_ title: String, _ slider: UISlider,
                      _ min: Float, _ max: Float, _ value: Float) -> UIStackView {
            slider.minimumValue = min
            slider.maximumValue = max
            slider.value = value
            slider.addTarget(self, action: #selector(controlsChanged), for: .valueChanged)
            let l = UILabel()
            l.text = title
            l.textColor = .white
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [l, slider])
            row.axis = .horizontal
            row.spacing = 10
            l.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return row
        }

        stack.addArrangedSubview(labelled("Cell", cellSlider, 6, 48, 16))
        stack.addArrangedSubview(labelled("Corner", radiusSlider, 0, 1, 0.30))
        stack.addArrangedSubview(labelled("Dot fill", dotScaleSlider, 0.3, 1.0, 0.84))
    }

    @objc private func controlsChanged() {
        effect?.config.cellSize = CGFloat(cellSlider.value)
        effect?.config.shape = .roundedSquare(cornerRadius: CGFloat(radiusSlider.value))
        effect?.config.dotScale = CGFloat(dotScaleSlider.value)
    }
}
