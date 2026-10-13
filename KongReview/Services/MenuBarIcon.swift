import AppKit

/// 菜单栏图标：App 图标（书 + 回环箭头 + k）的单色模板版，由 Tools/generate_icon.py --menubar 生成。
/// 设为模板图后，macOS 会按菜单栏深浅自动着色。
enum MenuBarIcon {
    static let png1x = "iVBORw0KGgoAAAANSUhEUgAAABIAAAASCAYAAABWzo5XAAABpUlEQVR4nI3TP2uUQRAG8N8bI4lBUMQUBtGIhf8KkxQWNmLpd7CytPcjWNkJFvaKrckHEP0CSiwEDUYjEpHYqBg9kstZ7LOX9847cGDY3ZlnZmdnnm2MlonWvoemZduLDkiTdRZT+I3v2B1zQZVJHMEhdLDV4DmWcLAasYqn+IQ38V3BVSziTOvyHbyspQ/rFuYwj1f4MQbXVt28eTf7dZxO6dcD6sb/OMk/tmL24u9n7EYXcCnP+hxfJwFfcSGYiu9X1EvmHpbTzLWcn+BG9jtZ14NZHoodAN1MM2uFd3AYD3ESm/EtBNuPrdyoNPiSHuwpvDkW4O1UdjS++WD7sTVRL+tcGjnRqqqjjPqewpsJbATbjh1450ps73J+gPPKFA8oA9gMZmVUj9pTW8RF/Gz5fuFuLlgyZmqVRzvZb6SCWdxXCPkaj3ACp4LpJuYfHg0z+5byBapMxvZtVEyDZziXps4ojJ5uJXif9WzL9kf53Nu57G0d+0zKnMJx5VNexrUovIiu4kMq6ygfett/yPRQhSOlsU/GYVtjf5qU8Vdbf1JV/gKHoatrxxRE2gAAAABJRU5ErkJggg=="
    static let png2x = "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAEMklEQVR4nN2Yz2sdVRTHP/PS1vozibGNij8p1oiCiuDCoLgTrSCKuNR/wI2Iq2RRNPgv2CwVFwV30lYXFamgC1FU0GKDgj9KRJNoq4n2Je/NdHG+58159817M08UxAPDzNx7zvd877n3nntm4D8mWfKcJf1Fcv+n/FX5KbyjBeQ1QC1dSLcHUOPc8d2u1k9kejUwDeyV4RbwO3B+hPOJ4MyJZyOcZ8AkcBVwufQvAL8Bv7rCIWAJuFHKu2TcBv4A1oDvga+BFV2ngZ9qRnsFcBtwt6454GZgH3AlcIn0Ohr0j8BiJofX1IC7fAp8JsB14BvgE7UB3Ac8CMyLxPUNcV3WwaajSxnmIjzn6tvGQvstsFvGs8AdwOvAWeA7yrVVJLhtLBLdBLtI/BTQv0iHXR3d38Gm1kkBfBX0cmBH+o67Gfrq/OQ0UHIyh5PwtoAn1LeTOPTRvoxN21KCNeoam8xe4Bk9HxeR1JETmgt2hxuSqiVzLERkGjil9uex7doZQigHPsTSieeiYw1IDZ3LHJv/WwS4J5DZGQHoU+dROiXblrA26V/UjQi5wyMh5ItqawdnbwKPAO/qfTsh5e+LAedIzaAqG93hPJY8Z4Fzave+C8B1cnJvaO8kOF3ZzgprPvHRd/ncRskV3lXgCykewrJ4QXkwdrDtPyHwFvABcCfwGJZ9/RiZFEYhzFWGnKFVhArdV7D5JoyqCHpZGOkk8B7wKHAGy1dfSidGG2GuJL56sittCErroe0GqssTH+Fp4HFsfQE8hR0jORbBTBgujt2IUJUMGCbtG5QRexo4KiJxiodh9EnVlDlAPHDPMjhlUfwoeRJ4S895IFkIw8Wx04iPJHQQKyHAElzVlLVC2wR26r+h5xZlhDJhIMyDwwhBxdZjcNvvZ3Db/4ll7ip5Dttlcdvvp8G2H0bIk9ZycLLAYGJ8ESu4XgVeCFEDeCnoLQSc5cTHWEfHFnCrRrYbeD+Q8mx8PtgdxRIgwGtqOynbTFhb/I2jI2bcE2HkU3LgOn40tHUVWCnqCfWkbDxqJxLssQhFw1cE6JFaAH4eYbcpHY8MwqgjU0sozrWTcrkWW7zLGvlxPT+LrasoTmZUldAjNE4J+zb9RVedzMmmSWR87fa2oBfaXoynhb8DbikSD2PrI5Up9S1LN9rGgj766hX5GfALgyFOJQLtoVwXq9iXyJre9wEHKD9/fOF7oqxKxFHWMuyEXqJMfm0ZXqbRTotEKl3KL9emfdtY2XsOS6w59sE4hQVmMabuS4G/wnuGpfkZ4Cbgduzj7x5sbcwMIeOygX3tfo6lgTPAD2r3T6MB31U/G5qczjPAXcADwEPA/Wr/GCvSPsLqoY0RGFV++n42ZEln/HUSD9Yug2T99F5P2jPKqevb2hW+iuh0XPHIpn86fOH6jhoV5X9VqkqT/4dcBJg2UX+vXZbmAAAAAElFTkSuQmCC"

    static func image() -> NSImage? {
        let img = NSImage(size: NSSize(width: 18, height: 18))
        for s in [png1x, png2x] {
            guard let data = Data(base64Encoded: s), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep)
        }
        guard !img.representations.isEmpty else { return nil }
        img.isTemplate = true
        img.accessibilityDescription = "KongReview"
        return img
    }
}
