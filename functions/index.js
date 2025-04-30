/**
 * Import function triggers from their respective submodules:
 *
 * const {onCall} = require("firebase-functions/v2/https");
 * const {onDocumentWritten} = require("firebase-functions/v2/firestore");
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

const {onRequest} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");

// Create and deploy your first functions
// https://firebase.google.com/docs/functions/get-started

// exports.helloWorld = onRequest((request, response) => {
//   logger.info("Hello logs!", {structuredData: true});
//   response.send("Hello from Firebase!");
// });

const functions = require('firebase-functions');
const admin = require('firebase-admin');
admin.initializeApp();

exports.sendCallNotification = functions.firestore
    .document('calls/{callId}')
    .onCreate((snap, context) => {
        const callData = snap.data();
        const receiverId = callData.receiver; // ID пользователя, которому звонят
        const channelName = callData.channelName;

        // Получаем токен устройства получателя
        return admin.firestore().collection('users').doc(receiverId).get()
            .then(userDoc => {
                if (!userDoc.exists) {
                    console.log('Пользователь не найден!');
                    return null;
                }

                const userToken = userDoc.data().fcmToken;
                if (!userToken) {
                    console.log('FCM токен не найден!');
                    return null;
                }

                // Настроить уведомление
                const payload = {
                    notification: {
                        title: 'Входящий звонок!',
                        body: `Пользователь ${callData.callerName} звонит вам.`,
                    },
                    data: {
                        channelName: channelName, // Передаем имя канала для ответа
                    },
                    token: userToken,
                };

                // Отправка уведомления
                return admin.messaging().send(payload);
            })
            .catch(error => {
                console.log('Ошибка при отправке уведомления:', error);
            });
    });