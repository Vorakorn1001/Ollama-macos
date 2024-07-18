import SwiftUI

struct ChatMessage: Identifiable, CustomStringConvertible {
    var id = UUID()
    var text: String
    var isUser: Bool
    var context: [Int]?

    var description: String {
        return "text: \(text)"
    }
}

class Chat: Identifiable, ObservableObject, CustomStringConvertible {
    var id = UUID()
    @Published var topic: String
    @Published var messages: [ChatMessage]
    @Published var create_at: Date?
    @Published var update_at: Date?
    @Published var context: [Int]

    init(topic: String, messages: [ChatMessage], create_at: Date? = nil, update_at: Date? = nil, context: [Int]) {
        self.topic = topic
        self.messages = messages
        self.create_at = create_at
        self.update_at = update_at
        self.context = context
    }

    var description: String {
        return "topic: \(topic), messages: \(messages)"
    }
}

struct OllamaResponse: Decodable {
    let model: String
    let created_at: String
    let response: String
    var done: Bool
    var done_reason: String?
    let context: [Int]?
    let total_duration: Int?
    let load_duration: Int?
    let prompt_eval_duration: Int?
    let eval_count: Int?
    let eval_duration: Int?
}

struct ChatView: View {
    @Binding var allChat: [Chat]
    @State private var chat: Chat
    @State private var inputField: String = ""
    @State private var currentResponse: String = ""
    @State private var chatHistory: [ChatMessage] = []

    init(chat: Chat, allChat: Binding<[Chat]>) {
        _chat = State(wrappedValue: chat)
        _chatHistory = State(initialValue: chat.messages)
        _allChat = allChat
    }

    var body: some View {
        VStack {
            HStack {
                Spacer().onAppear {
                    chatHistory = chat.messages
                }
                Button(action: {
                    print(chat)
                }, label: {
                    Text("Button")
                })
                Button(action: {
                    chat = Chat(topic: "New Chat", messages: [], context: [])
                    chatHistory = chat.messages
                }) {
                    Image(systemName: "plus.rectangle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .frame(width: 20, height: 16)
                .buttonStyle(PlainButtonStyle())
                .padding(10)
            }
            ScrollView {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(chatHistory) { message in
                        Text(message.text)
                            .padding(8)
                            .background(message.isUser ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                    }
                }
                .padding()
            }

            HStack {
                TextField("Type a message...", text: $inputField)
                    .onSubmit {
                        Task {
                            await sendMessage()
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Button(action: {
                    Task {
                        await sendMessage()
                    }
                }) {
                    Text("Send")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .foregroundColor(.clear)
                .padding(.trailing)
            }
            .padding(.bottom)
        }
        .navigationTitle("Ollama")
    }

    func sendMessage() async {
        let trimmedMessage = inputField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        chatHistory.append(ChatMessage(text: trimmedMessage, isUser: true, context: chat.context))
        inputField = ""
        chatHistory.append(ChatMessage(text: currentResponse, isUser: false, context: []))
        await sendHTTPPostRequest(message: trimmedMessage)
    }
    
    func create_request(model: String, prompt: String, context: [Int], stream: Bool) -> URLRequest {
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            fatalError("Invalid URL")
        }
        let json: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "context": context,
            "stream": stream
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: json)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        return request
    }

    func sendHTTPPostRequest(message: String) async {
        var request: URLRequest = create_request(model: "llama3", prompt: message, context: chat.context, stream: true)
        
        do {
            let (stream, _) = try await URLSession.shared.bytes(for: request)
            for try await line in stream.lines {
                guard let response = parse(jsonString: line) else { continue }
                if response.done {
                    currentResponse = ""
    
                    if chat.context.isEmpty {
                        let request = create_request(model: "llama3", prompt: "'''\(message)''' This is the first message of the chat your job is to give it a title of this chat\n***YOUR REPLY ONLY CONTAIN THE NAME OF THIS CHAT ANYTHING ELSE IS PROHIBIT AND ONLY GIVE A NORMAL TEXT NO SPECIAL CHARACTER***", context: [], stream: false)

                        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                            if let error = error {
                                print("Error: \(error)")
                                return
                            }

                            guard let data = data else {
                                print("No data received")
                                return
                            }

                            do {
                                let decoder = JSONDecoder()
                                let response = try decoder.decode(OllamaResponse.self, from: data)
                                
                                DispatchQueue.main.async {
                                    chat.topic = response.response
                                    allChat.append(chat)
                                }
                            } catch let decodingError {
                                print("Error decoding JSON: \(decodingError)")
                            }
                        }
                        task.resume()
                    }
                    
                    chat.context = response.context ?? []
                    chat.update_at = Date()
                } else {
                    currentResponse += response.response
                    chatHistory[chatHistory.indices.last ?? 0] = ChatMessage(text: currentResponse, isUser: false, context: [])
                    chat.messages = chatHistory
                }
            }
        } catch {
            print(error)
        }
    }

    func parse(jsonString: String) -> OllamaResponse? {
        if let jsonData = jsonString.data(using: .utf8) {
            do {
                let decodedData = try JSONDecoder().decode(OllamaResponse.self, from: jsonData)
                return decodedData
            } catch {
                print("Error decoding JSON string to struct: \(error)")
                return nil
            }
        }
        return nil
    }
}

struct Sidebar: View {
    @Binding var allChat: [Chat]

    var body: some View {
        VStack {
            List {
                ForEach(allChat) { chat in
                    NavigationLink(destination: ChatView(chat: chat, allChat: $allChat)) {
                        Text(chat.topic)
                    }
                }
            }
            .listStyle(SidebarListStyle())
        }
    }
}

struct ContentView: View {
    @State private var allChat: [Chat]
    let history: [Chat] = []
    let newChat = Chat(topic: "New Chat", messages: [], context: [])

    init() {
        _allChat = State(initialValue: history)
    }

    var body: some View {
        NavigationView {
            Sidebar(allChat: $allChat)
            ChatView(chat: newChat, allChat: $allChat)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
