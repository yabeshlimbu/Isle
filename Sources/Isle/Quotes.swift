import Foundation

/// Motivational "don't give up" quotes, changed every 5 minutes.
///
/// Quotes are dealt from a shuffled deck (built-in list + on-topic quotes
/// collected from ZenQuotes), so none repeats until all have been shown.
/// ZenQuotes returns 50 random quotes on any topic and only a few are about
/// perseverance, so the built-in list does most of the work.
final class QuoteModel: ObservableObject {
    struct Quote: Codable, Equatable {
        let text: String
        let author: String
    }

    @Published private(set) var current: Quote

    private static let rotateEvery: TimeInterval = 5 * 60
    private static let fetchEvery: TimeInterval = 60 * 60   // ZenQuotes rate-limits; hourly is plenty
    private static let endpoint = URL(string: "https://zenquotes.io/api/quotes")!
    private static let maxCollected = 400

    /// Every on-topic quote ever fetched from the web, kept so the library keeps growing.
    private var collected: [Quote] = []
    /// Shuffled quotes still to show this round. Each quote appears once per round,
    /// and the deck is saved, so relaunching doesn't bring back quotes you just saw.
    private var deck: [Quote] = []
    private var lastFetch = Date.distantPast
    private var fetching = false
    private var timer: Timer?

    /// Strict on purpose: words that are clearly about pushing on.
    private static let topic = try! NSRegularExpression(
        pattern: #"\b(give up|giving up|gave up|gives up|never quit|don'?t quit|quitters?|persever\w*|persist\w*|keep going|keep moving forward|keep trying|keep pushing|try again|tried again|failures?|get up|got up|rise again|overcom\w*|obstacles?|struggles?|resilien\w*|setbacks?|never stop|don'?t stop (?:until|till|now)|no matter how|hard work|determination|grit|undefeated)\b"#,
        options: [.caseInsensitive])

    init() {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String, as _: T.Type) -> T? {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        collected = load("quoteCollected", as: [Quote].self) ?? []
        deck = load("quoteDeck", as: [Quote].self) ?? []
        lastFetch = d.object(forKey: "quoteLastFetch") as? Date ?? .distantPast
        current = load("quoteCurrent", as: Quote.self) ?? Self.builtIn.randomElement()!
    }

    func start() {
        guard timer == nil else { return }
        let lastShown = UserDefaults.standard.object(forKey: "quoteShownAt") as? Date ?? .distantPast
        if Date().timeIntervalSince(lastShown) >= Self.rotateEvery { next() }
        fetchIfNeeded()
        let t = Timer(timeInterval: Self.rotateEvery, repeats: true) { [weak self] _ in self?.next() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Show another quote now (also used by the timer).
    func next() {
        if deck.isEmpty { reshuffle() }
        var quote = deck.removeFirst()
        if quote == current {                     // only possible right after a reshuffle
            if deck.isEmpty { reshuffle() }
            deck.append(quote)
            quote = deck.removeFirst()
        }
        current = quote
        save()
        fetchIfNeeded()
    }

    private func reshuffle() {
        var all: [Quote] = []
        for q in Self.builtIn + collected where !all.contains(where: { $0.text == q.text }) { all.append(q) }
        deck = all.shuffled()
        // Don't open a new round with the quote that's on screen.
        if deck.count > 1, deck[0] == current { deck.swapAt(0, Int.random(in: 1..<deck.count)) }
    }

    private func fetchIfNeeded() {
        guard !fetching, Date().timeIntervalSince(lastFetch) >= Self.fetchEvery else { return }
        fetching = true
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Isle", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let quotes = ok ? data.flatMap(Self.parse) ?? [] : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                self.lastFetch = Date()
                let known = Set((Self.builtIn + self.collected).map(\.text))
                var fresh: [Quote] = []
                for q in quotes where !known.contains(q.text) && !fresh.contains(q) { fresh.append(q) }
                self.collected.append(contentsOf: fresh)
                if self.collected.count > Self.maxCollected {
                    self.collected.removeFirst(self.collected.count - Self.maxCollected)
                }
                // New quotes go into the current round at random spots.
                for q in fresh { self.deck.insert(q, at: Int.random(in: 0...self.deck.count)) }
                self.save()
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> [Quote]? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let text = (item["q"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let author = (item["a"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 130,             // must fit in the island
                  !author.lowercased().contains("zenquotes"),   // the API's own "too many requests" notice
                  topic.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            else { return nil }
            return Quote(text: text, author: author)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(collected) { d.set(data, forKey: "quoteCollected") }
        if let data = try? JSONEncoder().encode(deck) { d.set(data, forKey: "quoteDeck") }
        if let data = try? JSONEncoder().encode(current) { d.set(data, forKey: "quoteCurrent") }
        d.set(lastFetch, forKey: "quoteLastFetch")
        d.set(Date(), forKey: "quoteShownAt")
    }

    private static let builtIn: [Quote] = [
        Quote(text: "It does not matter how slowly you go as long as you do not stop.", author: "Confucius"),
        Quote(text: "Our greatest glory is not in never falling, but in rising every time we fall.", author: "Oliver Goldsmith"),
        Quote(text: "It always seems impossible until it's done.", author: "Nelson Mandela"),
        Quote(text: "Success is not final, failure is not fatal: it is the courage to continue that counts.", author: "Winston Churchill"),
        Quote(text: "If you're going through hell, keep going.", author: "Winston Churchill"),
        Quote(text: "Fall seven times, stand up eight.", author: "Japanese proverb"),
        Quote(text: "I have not failed. I've just found 10,000 ways that won't work.", author: "Thomas Edison"),
        Quote(text: "Many of life's failures are people who did not realize how close they were to success when they gave up.", author: "Thomas Edison"),
        Quote(text: "Our greatest weakness lies in giving up. The most certain way to succeed is always to try just one more time.", author: "Thomas Edison"),
        Quote(text: "You may have to fight a battle more than once to win it.", author: "Margaret Thatcher"),
        Quote(text: "A river cuts through rock not because of its power, but because of its persistence.", author: "Jim Watkins"),
        Quote(text: "Perseverance is not a long race; it is many short races one after the other.", author: "Walter Elliot"),
        Quote(text: "Hard times don't create heroes. It is during the hard times when the hero within us is revealed.", author: "Bob Riley"),
        Quote(text: "Energy and persistence conquer all things.", author: "Benjamin Franklin"),
        Quote(text: "The difference between the impossible and the possible lies in a person's determination.", author: "Tommy Lasorda"),
        Quote(text: "Never give up on a dream just because of the time it will take to accomplish it.", author: "Earl Nightingale"),
        Quote(text: "Courage doesn't always roar. Sometimes it's the quiet voice at the end of the day saying, 'I will try again tomorrow.'", author: "Mary Anne Radmacher"),
        Quote(text: "Strength does not come from winning. Your struggles develop your strengths.", author: "Arnold Schwarzenegger"),
        Quote(text: "You just can't beat the person who never gives up.", author: "Babe Ruth"),
        Quote(text: "Continuous effort, not strength or intelligence, is the key to unlocking our potential.", author: "Liane Cordes"),
        Quote(text: "Don't watch the clock; do what it does. Keep going.", author: "Sam Levenson"),
        Quote(text: "The man who moves a mountain begins by carrying away small stones.", author: "Confucius"),
        Quote(text: "Rock bottom became the solid foundation on which I rebuilt my life.", author: "J.K. Rowling"),
        Quote(text: "Ever tried. Ever failed. No matter. Try again. Fail again. Fail better.", author: "Samuel Beckett"),
        Quote(text: "Character consists of what you do on the third and fourth tries.", author: "James A. Michener"),
        Quote(text: "Failure is simply the opportunity to begin again, this time more intelligently.", author: "Henry Ford"),
        Quote(text: "Whether you think you can, or you think you can't, you're right.", author: "Henry Ford"),
        Quote(text: "Success is stumbling from failure to failure with no loss of enthusiasm.", author: "Winston Churchill"),
        Quote(text: "Never, never, never give up.", author: "Winston Churchill"),
        Quote(text: "Genius is one percent inspiration and ninety-nine percent perspiration.", author: "Thomas Edison"),
        Quote(text: "It's not that I'm so smart, it's just that I stay with problems longer.", author: "Albert Einstein"),
        Quote(text: "Life is like riding a bicycle. To keep your balance you must keep moving.", author: "Albert Einstein"),
        Quote(text: "Do not judge me by my successes, judge me by how many times I fell down and got back up again.", author: "Nelson Mandela"),
        Quote(text: "If you can't fly then run, if you can't run then walk, if you can't walk then crawl, but keep moving forward.", author: "Martin Luther King Jr."),
        Quote(text: "Only those who dare to fail greatly can ever achieve greatly.", author: "Robert F. Kennedy"),
        Quote(text: "You miss 100% of the shots you don't take.", author: "Wayne Gretzky"),
        Quote(text: "I've failed over and over and over again in my life. And that is why I succeed.", author: "Michael Jordan"),
        Quote(text: "Obstacles don't have to stop you. If you run into a wall, don't turn around and give up.", author: "Michael Jordan"),
        Quote(text: "Champions keep playing until they get it right.", author: "Billie Jean King"),
        Quote(text: "The harder the conflict, the more glorious the triumph.", author: "Thomas Paine"),
        Quote(text: "Great works are performed not by strength but by perseverance.", author: "Samuel Johnson"),
        Quote(text: "Patience and perseverance have a magical effect before which difficulties disappear.", author: "John Quincy Adams"),
        Quote(text: "The secret of getting ahead is getting started.", author: "Mark Twain"),
        Quote(text: "Start where you are. Use what you have. Do what you can.", author: "Arthur Ashe"),
        Quote(text: "Believe you can and you're halfway there.", author: "Theodore Roosevelt"),
        Quote(text: "Do what you can, with what you have, where you are.", author: "Theodore Roosevelt"),
        Quote(text: "It is hard to fail, but it is worse never to have tried to succeed.", author: "Theodore Roosevelt"),
        Quote(text: "With ordinary talent and extraordinary perseverance, all things are attainable.", author: "Thomas Foxwell Buxton"),
        Quote(text: "Little by little, one travels far.", author: "J.R.R. Tolkien"),
        Quote(text: "Not all those who wander are lost.", author: "J.R.R. Tolkien"),
        Quote(text: "The best way out is always through.", author: "Robert Frost"),
        Quote(text: "In three words I can sum up everything I've learned about life: it goes on.", author: "Robert Frost"),
        Quote(text: "Though nobody can go back and make a new beginning, anyone can start over and make a new ending.", author: "Chico Xavier"),
        Quote(text: "The only real mistake is the one from which we learn nothing.", author: "Henry Ford"),
        Quote(text: "Act as if what you do makes a difference. It does.", author: "William James"),
        Quote(text: "Keep your face always toward the sunshine, and shadows will fall behind you.", author: "Walt Whitman"),
        Quote(text: "We must accept finite disappointment, but never lose infinite hope.", author: "Martin Luther King Jr."),
        Quote(text: "What we achieve inwardly will change outer reality.", author: "Plutarch"),
        Quote(text: "Difficulties strengthen the mind, as labor does the body.", author: "Seneca"),
        Quote(text: "The impediment to action advances action. What stands in the way becomes the way.", author: "Marcus Aurelius"),
        Quote(text: "No great thing is created suddenly.", author: "Epictetus"),
        Quote(text: "A smooth sea never made a skilled sailor.", author: "English proverb"),
        Quote(text: "The best time to plant a tree was 20 years ago. The second best time is now.", author: "Chinese proverb"),
        Quote(text: "Be not afraid of growing slowly; be afraid only of standing still.", author: "Chinese proverb"),
        Quote(text: "Dripping water hollows out stone, not through force but through persistence.", author: "Ovid"),
        Quote(text: "Be patient and tough; someday this pain will be useful to you.", author: "Ovid"),
        Quote(text: "Every strike brings me closer to the next home run.", author: "Babe Ruth"),
        Quote(text: "Tough times never last, but tough people do.", author: "Robert H. Schuller"),
        Quote(text: "Mistakes are proof that you are trying.", author: "Jennifer Lim"),
        Quote(text: "You are never too old to set another goal or to dream a new dream.", author: "Les Brown"),
        Quote(text: "Hope is the thing with feathers that perches in the soul.", author: "Emily Dickinson"),
        Quote(text: "I am not afraid of storms, for I am learning how to sail my ship.", author: "Louisa May Alcott"),
        Quote(text: "Nothing in the world can take the place of persistence.", author: "Calvin Coolidge"),
    ]
}
