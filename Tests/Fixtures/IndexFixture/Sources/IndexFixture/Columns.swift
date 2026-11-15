/// Columns after text that is not ASCII. Before each call to `columnProbe` there is, in turn:
/// nothing wider than a byte, Cyrillic (two bytes a letter, one UTF-16 unit), an emoji (four
/// bytes, two UTF-16 units) and a tab. Every layer has to report the same column for each call.
public func columnProbe(_ value: Int) -> Int { value }

public func columnProbeUses() -> Int {
    let ascii = columnProbe(1)
    let привет = 1; let cyrillic = columnProbe(привет)
    let smile = "😀"; let emoji = columnProbe(smile.count)
	let tabbed = columnProbe(3)
    return ascii + cyrillic + emoji + tabbed
}
